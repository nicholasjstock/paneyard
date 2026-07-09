// @vitest-environment node

import * as fs from 'fs'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'

const harnesses: WorkflowMcpTestHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.close()
  }
})

describe('workflow MCP worker lifecycle tools', () => {
  test('spawn_worker creates a running worker, persists it on the runtime, and publishes worker.spawned', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-1',
        role: 'worker',
        nickname: 'front-fixer',
        reason: 'Fix the coverage request CTA.',
        scope: 'fix-summary.md',
        prompt: 'Investigate and fix.',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      workerId: string
      status: string
      command: string
      nickname: string
    }
    expect(structuredContent.status).toBe('running')
    expect(structuredContent.command).toBe('codex')
    expect(structuredContent.nickname).toBe('front-fixer')

    const workersAfterSpawn = await harness.runtime.listWorkers()
    expect(workersAfterSpawn.map((worker) => worker.nickname)).toContain('front-fixer')
    const eventsAfterSpawn = await harness.bus.listRecentEvents()
    expect(eventsAfterSpawn.some((event) => event.type === 'worker.spawned')).toBe(true)
  })

  test('spawn_worker embeds the role .toml persona into the spawned prompt', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    // The harness's worker runtime uses an isolated tempDir as rootDir, so
    // seed a fake persona file there (matching the real .codex/agents/<role>.toml
    // layout) rather than depending on the real repo's file content.
    const agentsDir = path.join(harness.tempDir, '.codex', 'agents')
    fs.mkdirSync(agentsDir, { recursive: true })
    fs.writeFileSync(
      path.join(agentsDir, 'worker.toml'),
      'name = "worker"\ndeveloper_instructions = "Own frontend writes only."\n'
    )

    const result = await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-1',
        role: 'worker',
        nickname: 'front-fixer',
        reason: 'Fix the coverage request CTA.',
        scope: 'fix-summary.md',
        prompt: 'Investigate and fix the reported issue.',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { promptPath: string }
    const promptContent = fs.readFileSync(structuredContent.promptPath, 'utf8')

    expect(promptContent).toContain('Own frontend writes only.')
    expect(promptContent).toContain('Current task:')
    expect(promptContent).toContain('Investigate and fix the reported issue.')
  })

  test('spawn_worker rejects an unknown role before it reaches the runtime', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-1',
        role: 'not_a_role',
        nickname: 'ghost',
        reason: 'n/a',
        scope: 'n/a',
        prompt: 'n/a',
      },
    })

    expect(result.isError).toBe(true)
    expect(await harness.runtime.listWorkers()).toHaveLength(0)
  })

  test('list_workers filters by runId and activeOnly through the tool', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-a',
        role: 'worker',
        nickname: 'front-fixer',
        reason: 'n/a',
        scope: 'n/a',
        prompt: 'n/a',
      },
    })
    await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-b',
        role: 'worker',
        nickname: 'back-fixer',
        reason: 'n/a',
        scope: 'n/a',
        prompt: 'n/a',
      },
    })

    const result = await harness.client.callTool({
      name: 'list_workers',
      arguments: { runId: 'run-a', activeOnly: true },
    })

    const structuredContent = result.structuredContent as { workers: Array<{ nickname: string; runId: string }> }
    expect(structuredContent.workers).toHaveLength(1)
    expect(structuredContent.workers[0]?.nickname).toBe('front-fixer')
    expect(structuredContent.workers[0]?.runId).toBe('run-a')
  })

  test('stop_worker stops by nickname, persists the stop reason, and publishes worker.stopped', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'spawn_worker',
      arguments: {
        runId: 'run-1',
        role: 'worker',
        nickname: 'front-fixer',
        reason: 'n/a',
        scope: 'n/a',
        prompt: 'n/a',
      },
    })

    const result = await harness.client.callTool({
      name: 'stop_worker',
      arguments: { nickname: 'front-fixer', reason: 'Fix landed.' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { status: string; stopReason: string | null }
    expect(structuredContent.status).toBe('stopped')
    expect(structuredContent.stopReason).toBe('Fix landed.')

    expect(await harness.runtime.listWorkers({ activeOnly: true })).toHaveLength(0)
    const eventsAfterStop = await harness.bus.listRecentEvents()
    expect(eventsAfterStop.some((event) => event.type === 'worker.stopped')).toBe(true)
  })

  test('stop_worker rejects when neither workerId nor nickname is supplied', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'stop_worker',
      arguments: { reason: 'n/a' },
    })

    expect(result.isError).toBe(true)
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(content?.text).toContain('stop_worker requires workerId or nickname')
  })

})
