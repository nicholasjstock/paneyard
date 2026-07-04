// @vitest-environment node

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'
import { ROOT_DIR } from '../workflow-mcp-app'
import type { GuardedCommand } from '../workflow-mcp'

const harnesses: WorkflowMcpTestHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.close()
  }
})

describe('workflow MCP command tools', () => {
  test('read_orchestrator_state returns the default empty state before any writes', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'read_orchestrator_state',
      arguments: { runId: 'demo-2026-07-03' },
    })

    expect(result.isError).toBeFalsy()
    expect(result.structuredContent).toEqual({
      runId: 'demo-2026-07-03',
      phase: 'starting',
      tickCount: 0,
      lastPlanSummary: null,
      pendingSpawnKeys: [],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: null,
    })
  })

  test('write_orchestrator_state persists a decision state that read_orchestrator_state returns unchanged', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const orchestratorState = {
      runId: 'demo-2026-07-03',
      phase: 'planning',
      tickCount: 2,
      lastPlanSummary: 'Latest planner summary.',
      pendingSpawnKeys: ['["demo-2026-07-03","worker","recorder-report.md"]'],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: '2026-07-03T12:00:00.000Z',
    }

    const writeResult = await harness.client.callTool({
      name: 'write_orchestrator_state',
      arguments: orchestratorState,
    })

    expect(writeResult.isError).toBeFalsy()
    expect((writeResult.structuredContent as { statePath: string }).statePath).toContain(
      '/orchestrator-state/demo-2026-07-03.json'
    )

    const readResult = await harness.client.callTool({
      name: 'read_orchestrator_state',
      arguments: { runId: 'demo-2026-07-03' },
    })

    expect(readResult.isError).toBeFalsy()
    expect(readResult.structuredContent).toEqual(orchestratorState)
  })

  test('build_guarded_command resolves frontend_typecheck without executing anything', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'build_guarded_command',
      arguments: { operation: 'frontend_typecheck' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { command: string; args: string[]; cwd: string }
    expect(structuredContent.command).toBe('npx')
    expect(structuredContent.args).toEqual(['tsc', '--noEmit'])
  })

  test('build_guarded_command surfaces the handler validation error for an incomplete record_demo request', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'build_guarded_command',
      arguments: { operation: 'record_demo' },
    })

    expect(result.isError).toBe(true)
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(content?.text).toContain('record_demo requires')
  })

  test('run_guarded_command maps a successful injected run to exitCode 0 and success true', async () => {
    const harness = await createMcpTestHarness({
      commandRunner: () => ({ status: 0, stdout: 'typecheck ok\n', stderr: '' }),
    })
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'run_guarded_command',
      arguments: { operation: 'frontend_typecheck' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      exitCode: number
      success: boolean
      stdout: string
    }
    expect(structuredContent.exitCode).toBe(0)
    expect(structuredContent.success).toBe(true)
    expect(structuredContent.stdout).toBe('typecheck ok\n')
  })

  test('run_guarded_command maps a non-zero injected exit to success false without setting isError', async () => {
    const harness = await createMcpTestHarness({
      commandRunner: () => ({ status: 1, stdout: '', stderr: 'type error\n' }),
    })
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'run_guarded_command',
      arguments: { operation: 'frontend_typecheck' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { exitCode: number; success: boolean; stderr: string }
    expect(structuredContent.exitCode).toBe(1)
    expect(structuredContent.success).toBe(false)
    expect(structuredContent.stderr).toBe('type error\n')
  })

  test('run_guarded_command threads scenario/executionMode/frontendUrl into the command handed to the runner', async () => {
    const receivedSpecs: GuardedCommand[] = []
    const harness = await createMcpTestHarness({
      commandRunner: (spec) => {
        receivedSpecs.push(spec)
        return { status: 0, stdout: '', stderr: '' }
      },
    })
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'run_guarded_command',
      arguments: {
        operation: 'record_demo',
        scenario: 'phone',
        executionMode: 'docker',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(receivedSpecs).toHaveLength(1)
    expect(receivedSpecs[0]).toEqual({
      command: 'bin/record_demo',
      args: ['phone', '--docker', '--frontend-url=http://localhost:5174'],
      cwd: ROOT_DIR,
    })
  })
})
