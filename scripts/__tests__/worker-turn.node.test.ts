// @vitest-environment node

import { describe, expect, test } from 'vitest'

import { runWorkerTurn, type WorkerTurnBus } from '../worker-turn'

function createFakeBus(): WorkerTurnBus & {
  requests: Array<{
    requestId: string
    runId: string
    askedBy: string
    scope: string
    text: string
    context?: string
    requestedRole: string
    status: 'open' | 'fulfilled' | 'dismissed'
    fulfilledWorkerId?: string | null
  }>
} {
  const requests: Array<{
    requestId: string
    runId: string
    askedBy: string
    scope: string
    text: string
    context?: string
    requestedRole: string
    status: 'open' | 'fulfilled' | 'dismissed'
    fulfilledWorkerId?: string | null
  }> = []
  let nextId = 1

  return {
    requests,
    appendSpawnRequest(args) {
      const requestId = `req-${nextId}`
      nextId += 1
      requests.push({ ...args, requestId, status: 'open' })
      return { requestId }
    },
    listSpawnRequests() {
      return requests
    },
  }
}

describe('worker turn', () => {
  test('requests a follow-up planner via the bus with the result and followingSteps as context', () => {
    const bus = createFakeBus()

    const result = runWorkerTurn({
      runId: 'run-6',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'The frontend coverage-request button does not respond to clicks.',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      previousState: {
        runId: 'run-6',
        phase: 'planning',
        tickCount: 2,
        lastPlanSummary: 'previous summary',
        pendingSpawnKeys: [],
        followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the fix.' }],
        lastStallFinding: null,
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(bus.requests).toHaveLength(1)
    expect(bus.requests[0]?.requestedRole).toBe('planner')
    expect(bus.requests[0]?.askedBy).toBe('worker')
    expect(bus.requests[0]?.scope).toBe('workflow-plan.md')
    expect(bus.requests[0]?.context).toContain('The frontend coverage-request button does not respond to clicks.')
    expect(bus.requests[0]?.context).toContain('verifier-report.md')
    expect(result.plannerRequest.requestId).toBe(bus.requests[0]?.requestId)
    // worker_turn never decides anything itself — it just carries the
    // previous followingSteps forward for the spawned planner to consume.
    expect(result.nextState.followingSteps).toEqual([
      { owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the fix.' },
    ])
  })

  test('does not spawn a process itself — the request is left for the supervisor to fulfill', () => {
    const bus = createFakeBus()

    runWorkerTurn({
      runId: 'run-7',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(bus.requests[0]?.status).toBe('open')
  })

  test('reuses an existing open planner request instead of appending a duplicate', () => {
    const bus = createFakeBus()

    const first = runWorkerTurn({
      runId: 'run-9',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    const second = runWorkerTurn({
      runId: 'run-9',
      role: 'worker',
      nickname: 'worker-2',
      scope: 'recorder-report.md',
      result: 'a different result',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(bus.requests).toHaveLength(1)
    expect(second.plannerRequest.requestId).toBe(first.plannerRequest.requestId)
  })

  test('reuses an already-fulfilled planner request while its planner is still active', () => {
    const bus = createFakeBus()

    const first = runWorkerTurn({
      runId: 'run-10',
      role: 'worker',
      nickname: 'worker',
      scope: 'recorder-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })
    bus.requests[0]!.status = 'fulfilled'
    bus.requests[0]!.fulfilledWorkerId = 'planner-worker-1'

    const second = runWorkerTurn({
      runId: 'run-10',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      activeWorkerIds: new Set(['planner-worker-1']),
    })

    expect(bus.requests).toHaveLength(1)
    expect(second.plannerRequest.requestId).toBe(first.plannerRequest.requestId)
  })

  test('requests a fresh planner once the previously fulfilled one has stopped', () => {
    const bus = createFakeBus()

    const first = runWorkerTurn({
      runId: 'run-14',
      role: 'worker',
      nickname: 'worker',
      scope: 'recorder-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })
    bus.requests[0]!.status = 'fulfilled'
    bus.requests[0]!.fulfilledWorkerId = 'planner-worker-1'

    // That planner has since stopped — activeWorkerIds no longer contains
    // it, so this slot is free again, unlike a one-time worker artifact
    // that would stay "done" forever regardless.
    const second = runWorkerTurn({
      runId: 'run-14',
      role: 'worker',
      nickname: 'worker-2',
      scope: 'verifier-report.md',
      result: 'a later, different result',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      activeWorkerIds: new Set(),
    })

    expect(bus.requests).toHaveLength(2)
    expect(second.plannerRequest.requestId).not.toBe(first.plannerRequest.requestId)
  })

  test('appends a fresh request when the prior one was dismissed', () => {
    const bus = createFakeBus()

    const first = runWorkerTurn({
      runId: 'run-11',
      role: 'worker',
      nickname: 'worker',
      scope: 'recorder-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })
    bus.requests[0]!.status = 'dismissed'

    const second = runWorkerTurn({
      runId: 'run-11',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(bus.requests).toHaveLength(2)
    expect(second.plannerRequest.requestId).not.toBe(first.plannerRequest.requestId)
  })

  test('nextState defaults phase/tickCount and followingSteps when no previousState is given', () => {
    const bus = createFakeBus()

    const result = runWorkerTurn({
      runId: 'run-12',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.nextState.phase).toBe('starting')
    expect(result.nextState.tickCount).toBe(0)
    expect(result.nextState.followingSteps).toEqual([])
  })

  test('nextState carries orchestrator/planner-owned fields forward untouched', () => {
    const bus = createFakeBus()

    const result = runWorkerTurn({
      runId: 'run-13',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      previousState: {
        runId: 'run-13',
        phase: 'stalled',
        tickCount: 5,
        lastPlanSummary: 'old summary',
        pendingSpawnKeys: ['a-key'],
        followingSteps: [{ owner: 'worker', artifact: 'stale.md', successCheck: 'stale' }],
        lastStallFinding: 'old finding',
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(result.nextState.phase).toBe('stalled')
    expect(result.nextState.tickCount).toBe(5)
    expect(result.nextState.lastStallFinding).toBe('old finding')
    expect(result.nextState.lastPlanSummary).toBe('old summary')
    expect(result.nextState.pendingSpawnKeys).toEqual(['a-key'])
    expect(result.nextState.followingSteps).toEqual([{ owner: 'worker', artifact: 'stale.md', successCheck: 'stale' }])
  })
})
