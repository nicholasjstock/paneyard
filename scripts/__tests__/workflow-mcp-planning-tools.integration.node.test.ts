// @vitest-environment node

import * as fs from 'fs'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'
import { spawnRequestedWorkers } from '../supervisor-loop'

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
    const structuredContent = result.structuredContent as {
      nextStep: { owner: string } | null
      followingSteps: Array<{ owner: string }>
    }
    expect(structuredContent.nextStep?.owner).toBe('worker')
    expect(structuredContent.followingSteps.map((step) => step.owner)).toEqual(['worker'])
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

  test('worker_turn never publishes a plan itself — it only spawns a planner to decide', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'worker_turn',
      arguments: {
        runId: 'run-1',
        role: 'worker',
        nickname: 'worker',
        scope: 'verifier-report.md',
        result: 'The frontend coverage-request button does not respond to clicks.',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      plannerRequest: { requestId: string }
    }
    expect(structuredContent.plannerRequest.requestId).toBeTruthy()

    // worker_turn only requests the follow-up planner — it never spawns a
    // process itself, so no worker exists yet and the request is still open,
    // waiting for the supervisor's next tick to fulfill it.
    const openRequests = await harness.bus.listOpenSpawnRequests()
    expect(openRequests).toHaveLength(1)
    expect(openRequests[0]?.requestId).toBe(structuredContent.plannerRequest.requestId)
    expect(openRequests[0]?.requestedRole).toBe('planner')
    expect(openRequests[0]?.scope).toBe('workflow-plan.md')
    expect(await harness.runtime.listWorkers()).toEqual([])
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
        role: 'worker',
        nickname: 'worker',
        scope: 'verifier-report.md',
        result: 'The frontend coverage-request button does not respond to clicks.',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()

    // worker_turn only requests the follow-up planner; the supervisor is
    // what actually spawns it, on its next tick.
    const spawned = await spawnRequestedWorkers({ runId: 'run-2', workerRuntime: harness.runtime, bus: harness.bus })
    const plannerWorker = spawned.find((worker) => worker.role === 'planner')

    expect(plannerWorker).toBeDefined()

    const promptContent = fs.readFileSync(plannerWorker!.promptPath, 'utf8')
    expect(promptContent).toContain('Own planning only.')
    expect(promptContent).toContain('The frontend coverage-request button does not respond to clicks.')

    const currentWorkers = await harness.runtime.listWorkers()
    expect(currentWorkers.some((worker) => worker.role === 'planner')).toBe(true)
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

  test('worker_turn only ever has one planner worker running for a given run across repeated calls', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const args = {
      runId: 'run-single-planner',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    }

    await harness.client.callTool({ name: 'worker_turn', arguments: args })
    await harness.client.callTool({ name: 'worker_turn', arguments: { ...args, nickname: 'worker-2' } })

    // Reused rather than duplicated at the request level already, so even
    // before anything is spawned there's only one planner request open.
    const allOpenRequests = await harness.bus.listOpenSpawnRequests()
    const plannerRequests = allOpenRequests.filter((request) => request.requestedRole === 'planner')
    expect(plannerRequests).toHaveLength(1)

    await spawnRequestedWorkers({ runId: 'run-single-planner', workerRuntime: harness.runtime, bus: harness.bus })

    const activePlanners = await harness.runtime.listWorkers({ runId: 'run-single-planner', activeOnly: true })
    const runningPlanners = activePlanners.filter((worker) => worker.role === 'planner')
    expect(runningPlanners).toHaveLength(1)
  })

  test('worker_turn carries the previous followingSteps queue forward into nextState untouched', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'planner_turn',
      arguments: {
        runId: 'run-next-state',
        summary: 'Route to a scoped fix, then re-verify.',
        nextStep: { owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Applies the fix.' },
        followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the fix.' }],
      },
    })

    const result = await harness.client.callTool({
      name: 'worker_turn',
      arguments: {
        runId: 'run-next-state',
        role: 'worker',
        nickname: 'worker',
        scope: 'fix-summary.md',
        result: 'irrelevant',
        task: 'Validate the phone flow',
        scenario: 'phone',
        frontendUrl: 'http://localhost:5174',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      nextState: { followingSteps: Array<{ artifact: string }> }
    }
    expect(structuredContent.nextState.followingSteps.map((step) => step.artifact)).toEqual(['verifier-report.md'])

    const readResult = await harness.client.callTool({
      name: 'read_orchestrator_state',
      arguments: { runId: 'run-next-state' },
    })
    const readState = readResult.structuredContent as { followingSteps: Array<{ artifact: string }> }
    expect(readState.followingSteps.map((step) => step.artifact)).toEqual(['verifier-report.md'])
  })

  test('planner_turn publishes a spawn request for nextStep and persists followingSteps', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'planner_turn',
      arguments: {
        runId: 'run-3',
        summary: 'Frontend button unresponsive; route to a scoped fix, then re-verify.',
        nextStep: { owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Button responds to taps on the phone view.' },
        followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the button now responds.' }],
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      jobs: Array<{ requestId: string; step: { owner: string } }>
      nextState: { followingSteps: Array<{ artifact: string }> }
    }
    expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['worker'])
    expect(structuredContent.nextState.followingSteps.map((step) => step.artifact)).toEqual(['verifier-report.md'])

    const openRequests = await harness.bus.listOpenSpawnRequests()
    expect(openRequests.map((request) => request.requestedRole)).toEqual(['worker'])
    expect(openRequests[0]?.askedBy).toBe('planner')
  })

  test('planner_turn rejects an unknown role in nextStep via the Zod schema', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'planner_turn',
      arguments: {
        runId: 'run-3',
        summary: 'irrelevant',
        nextStep: { owner: 'not_a_role', artifact: 'fix-summary.md', successCheck: 'irrelevant' },
        followingSteps: [],
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

  test('answer_user_question marks a question answered and drops it from list_open_user_questions but not list_user_questions', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const appendResult = await harness.client.callTool({
      name: 'append_user_question',
      arguments: {
        runId: 'run-question',
        askedBy: 'planner',
        scope: 'environment choice',
        text: 'Should this workflow continue against staging or production?',
        priority: 'blocking',
      },
    })
    const question = appendResult.structuredContent as { questionId: string }

    const answerResult = await harness.client.callTool({
      name: 'answer_user_question',
      arguments: {
        questionId: question.questionId,
        answeredBy: 'user',
        answerText: 'Continue against staging.',
      },
    })

    expect(answerResult.isError).toBeFalsy()
    const answered = answerResult.structuredContent as {
      status: string
      answeredBy: string
      answerText: string
    }
    expect(answered.status).toBe('answered')
    expect(answered.answeredBy).toBe('user')
    expect(answered.answerText).toBe('Continue against staging.')

    const openResult = await harness.client.callTool({ name: 'list_open_user_questions', arguments: {} })
    expect((openResult.structuredContent as { questions: unknown[] }).questions).toHaveLength(0)

    const allResult = await harness.client.callTool({ name: 'list_user_questions', arguments: {} })
    const allQuestions = (allResult.structuredContent as { questions: Array<{ questionId: string; status: string }> })
      .questions
    expect(allQuestions).toHaveLength(1)
    expect(allQuestions[0]?.questionId).toBe(question.questionId)
    expect(allQuestions[0]?.status).toBe('answered')
  })

  test('answer_user_question surfaces an unknown questionId as isError instead of a transport rejection', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'answer_user_question',
      arguments: {
        questionId: 'does-not-exist',
        answeredBy: 'user',
        answerText: 'irrelevant',
      },
    })

    expect(result.isError).toBe(true)
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(content?.text).toContain('Unknown user question')
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

    const openRequests = await harness.bus.listOpenSpawnRequests()
    expect(openRequests).toHaveLength(1)
    expect(openRequests[0]?.requestedRole).toBe('planner')
    expect(openRequests[0]?.scope).toBe('workflow-plan.md')
  })

  test('publish_planner_jobs runs the planner and appends a spawn request for nextStep', async () => {
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
    expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['worker'])

    const openRequestsForJobs = await harness.bus.listOpenSpawnRequests()
    const openRequestIds = openRequestsForJobs.map((request) => request.requestId)
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
    expect(await harness.bus.listOpenSpawnRequests()).toHaveLength(firstIds.length)
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
