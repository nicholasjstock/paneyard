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

describe('workflow MCP planning tools', () => {
  test('plan_workflow_iteration returns the baseline record-then-verify plan over the protocol', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'plan_workflow_iteration',
      arguments: {
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { steps: Array<{ owner: string }> }
    expect(structuredContent.steps.map((step) => step.owner)).toEqual(['orchestrator', 'demo_recorder', 'demo_verifier'])
  })

  test('plan_workflow_iteration rejects a non-URL frontendUrl via the Zod schema', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'plan_workflow_iteration',
      arguments: {
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'not-a-url',
      },
    })

    expect(result.isError).toBe(true)
  })

  test('worker_turn routes a worker-reported result to the matching fixer and publishes bus jobs', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'worker_turn',
      arguments: {
        runId: 'run-1',
        role: 'demo_verifier',
        nickname: 'demo-verifier',
        scope: 'verifier-report.md',
        result: 'The frontend coverage-request button does not respond to clicks.',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      plan: { steps: Array<{ owner: string }> }
      jobs: Array<{ requestId: string; step: { owner: string } }>
    }
    expect(structuredContent.plan.steps.map((step) => step.owner)).toContain('front_fixer')
    expect(structuredContent.jobs.map((job) => job.step.owner)).toContain('front_fixer')

    const openRequestIds = harness.bus.listOpenSpawnRequests().map((request) => request.requestId)
    for (const job of structuredContent.jobs) {
      expect(openRequestIds).toContain(job.requestId)
    }
  })

  test('worker_turn spawns a real planner worker with the persona and reported result in its prompt', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    // The harness's worker runtime uses an isolated tempDir as rootDir, so
    // seed a fake persona file there (matching the real .codex/agents/<role>.toml
    // layout) rather than depending on the real repo's file content.
    const agentsDir = path.join(harness.tempDir, '.codex', 'agents')
    fs.mkdirSync(agentsDir, { recursive: true })
    fs.writeFileSync(path.join(agentsDir, 'planner.toml'), 'name = "planner"\ndeveloper_instructions = "Own planning only."\n')

    const result = await harness.client.callTool({
      name: 'worker_turn',
      arguments: {
        runId: 'run-2',
        role: 'demo_verifier',
        nickname: 'demo-verifier',
        scope: 'verifier-report.md',
        result: 'The frontend coverage-request button does not respond to clicks.',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      plannerWorker: { role: string; nickname: string; promptPath: string } | null
    }
    expect(structuredContent.plannerWorker).not.toBeNull()
    expect(structuredContent.plannerWorker?.role).toBe('planner')

    const promptContent = fs.readFileSync(structuredContent.plannerWorker!.promptPath, 'utf8')
    expect(promptContent).toContain('Own planning only.')
    expect(promptContent).toContain('The frontend coverage-request button does not respond to clicks.')

    expect(harness.runtime.listWorkers().some((worker) => worker.role === 'planner')).toBe(true)
  })

  test('worker_turn rejects an unknown role via the Zod schema', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'worker_turn',
      arguments: {
        runId: 'run-1',
        role: 'not_a_role',
        nickname: 'demo-verifier',
        scope: 'verifier-report.md',
        result: 'irrelevant',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBe(true)
  })

  test('planner_turn publishes one spawn request per decided step', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'planner_turn',
      arguments: {
        runId: 'run-3',
        summary: 'Frontend button unresponsive; route to front_fixer, then re-verify.',
        steps: [
          { owner: 'front_fixer', artifact: 'fix-summary.md', successCheck: 'Button responds to taps on the phone view.' },
          { owner: 'demo_verifier', artifact: 'verifier-report.md', successCheck: 'Confirms the button now responds.' },
        ],
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { jobs: Array<{ requestId: string; step: { owner: string } }> }
    expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['front_fixer', 'demo_verifier'])

    const openRequests = harness.bus.listOpenSpawnRequests()
    expect(openRequests.map((request) => request.requestedRole)).toEqual(['front_fixer', 'demo_verifier'])
    for (const request of openRequests) {
      expect(request.askedBy).toBe('planner')
    }
  })

  test('planner_turn rejects an unknown role in a step via the Zod schema', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'planner_turn',
      arguments: {
        runId: 'run-3',
        summary: 'irrelevant',
        steps: [{ owner: 'not_a_role', artifact: 'fix-summary.md', successCheck: 'irrelevant' }],
      },
    })

    expect(result.isError).toBe(true)
  })

  test('append_user_question writes a planner-blocked user question to the bus and list_open_user_questions returns it', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const appendResult = await harness.client.callTool({
      name: 'append_user_question',
      arguments: {
        runId: 'run-question',
        askedBy: 'planner',
        scope: 'environment choice',
        text: 'Should this workflow continue against staging or production?',
        context: 'The planner is blocked until the target environment is chosen.',
        priority: 'blocking',
        tags: ['planner', 'blocked'],
      },
    })

    expect(appendResult.isError).toBeFalsy()
    const question = appendResult.structuredContent as { questionId: string; askedBy: string; priority: string }
    expect(question.askedBy).toBe('planner')
    expect(question.priority).toBe('blocking')

    const listResult = await harness.client.callTool({
      name: 'list_open_user_questions',
      arguments: {},
    })

    expect(listResult.isError).toBeFalsy()
    const structuredContent = listResult.structuredContent as {
      questions: Array<{ questionId: string; askedBy: string; text: string }>
    }
    expect(structuredContent.questions).toHaveLength(1)
    expect(structuredContent.questions[0]?.questionId).toBe(question.questionId)
    expect(structuredContent.questions[0]?.askedBy).toBe('planner')
  })

  test('queue_long_phone_demo_planner_job appends a blocking planner seed request for the long phone demo video', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'queue_long_phone_demo_planner_job',
      arguments: {
        runId: 'run-phone-demo-long',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      requestId: string
      requestedRole: string
      priority: string
      text: string
    }
    expect(structuredContent.requestedRole).toBe('planner')
    expect(structuredContent.priority).toBe('blocking')
    expect(structuredContent.text).toContain('long phone demo video')

    const openRequests = harness.bus.listOpenSpawnRequests()
    expect(openRequests).toHaveLength(1)
    expect(openRequests[0]?.requestedRole).toBe('planner')
    expect(openRequests[0]?.scope).toBe('workflow-plan.md')
  })

  test('publish_planner_jobs runs the planner and appends spawn requests in step order', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'publish_planner_jobs',
      arguments: {
        runId: 'run-1',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { jobs: Array<{ requestId: string; step: { owner: string } }> }
    expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['demo_recorder', 'demo_verifier'])

    const openRequestIds = harness.bus.listOpenSpawnRequests().map((request) => request.requestId)
    for (const job of structuredContent.jobs) {
      expect(openRequestIds).toContain(job.requestId)
    }
  })

  test('publish_planner_jobs is idempotent across repeated calls for the same run', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const args = {
      runId: 'run-1',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    }

    const first = await harness.client.callTool({ name: 'publish_planner_jobs', arguments: args })
    const second = await harness.client.callTool({ name: 'publish_planner_jobs', arguments: args })

    const firstIds = (first.structuredContent as { jobs: Array<{ requestId: string }> }).jobs.map((job) => job.requestId)
    const secondIds = (second.structuredContent as { jobs: Array<{ requestId: string }> }).jobs.map((job) => job.requestId)

    expect(secondIds).toEqual(firstIds)
    expect(harness.bus.listOpenSpawnRequests()).toHaveLength(firstIds.length)
  })

  test('run_orchestrator_turn persists a tick history entry alongside the state, retrievable via read_orchestrator_tick_history', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const args = {
      runId: 'run-tick-history',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    }

    await harness.client.callTool({ name: 'run_orchestrator_turn', arguments: args })
    await harness.client.callTool({ name: 'run_orchestrator_turn', arguments: args })

    const historyResult = await harness.client.callTool({
      name: 'read_orchestrator_tick_history',
      arguments: { runId: 'run-tick-history' },
    })

    const structuredContent = historyResult.structuredContent as {
      runId: string
      entries: Array<{ tickCount: number }>
    }

    expect(structuredContent.runId).toBe('run-tick-history')
    expect(structuredContent.entries.map((entry) => entry.tickCount)).toEqual([1, 2])
  })
})
