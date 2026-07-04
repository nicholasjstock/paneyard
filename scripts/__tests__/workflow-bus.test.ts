import { describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'

function createMemoryFs() {
  const files = new Map<string, string>()

  return {
    mkdirSync() {},
    writeFileSync(filePath: string, content: string) {
      files.set(filePath, content)
    },
    readFileSync(filePath: string) {
      const content = files.get(filePath)
      if (content == null) {
        throw new Error(`missing file: ${filePath}`)
      }

      return content
    },
    existsSync(filePath: string) {
      return files.has(filePath)
    },
  }
}

function makeBus() {
  return createWorkflowBus({
    storagePath: '/virtual/workflow-bus.json',
    fileSystem: createMemoryFs(),
  })
}

describe('workflow bus', () => {
  test('stores and fulfills spawn requests in one shared ledger', () => {
    const bus = makeBus()

    const request = bus.appendSpawnRequest({
      runId: 'demo-need-worker',
      askedBy: 'worker',
      scope: 'deeper verification',
      text: 'Need a verifier focused on crop geometry and frame composition.',
      context: 'Planner identified a missing verifier and queued a spawn request.',
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['verification', 'blocking'],
    })

    const fulfilled = bus.fulfillSpawnRequest({
      requestId: request.requestId,
      fulfilledBy: 'supervisor_loop',
      fulfillmentNote: 'Spawned demo-verifier.',
    })

    expect(request.status).toBe('open')
    expect(request.context).toBe('Planner identified a missing verifier and queued a spawn request.')
    expect(bus.listOpenSpawnRequests()).toHaveLength(0)
    expect(fulfilled.status).toBe('fulfilled')
    expect(fulfilled.fulfilledBy).toBe('supervisor_loop')
    expect(fulfilled.fulfillmentNote).toContain('demo-verifier')
  })

  test('emits spawn-request lifecycle events', () => {
    const bus = makeBus()
    const request = bus.appendSpawnRequest({
      runId: 'demo-2',
      askedBy: 'orchestrator',
      scope: 'fix-summary.md',
      text: 'Need a frontend fixer.',
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'planner-job'],
    })

    const events = bus.listRecentEvents(1)
    expect(events[0]?.type).toBe('spawn_request.created')
    expect(events[0]?.payload).toMatchObject({
      requestId: request.requestId,
      requestedRole: 'worker',
      priority: 'blocking',
    })
  })

  test('publishes run status events for startup and phase changes', () => {
    const bus = makeBus()

    const status = bus.publishRunStatus({
      runId: 'demo-3',
      phase: 'planning',
      owner: 'orchestrator',
      summary: 'Bootstrapping the production demo run',
    })

    expect(status.runId).toBe('demo-3')
    expect(status.phase).toBe('planning')
    expect(status.owner).toBe('orchestrator')

    const [event] = bus.listRecentEvents(1)
    expect(event?.type).toBe('run.status')
    expect(event?.payload).toMatchObject({
      runId: 'demo-3',
      phase: 'planning',
      owner: 'orchestrator',
    })
  })

  test('publishes worker lifecycle events at the orchestrator level', () => {
    const bus = makeBus()

    const spawned = bus.publishWorkerSpawned({
      runId: 'demo-4',
      owner: 'orchestrator',
      role: 'worker',
      nickname: 'demo-recorder',
      reason: 'Recorder needed for the next recording pass.',
    })

    const stopped = bus.publishWorkerStopped({
      runId: 'demo-4',
      owner: 'orchestrator',
      role: 'worker',
      nickname: 'demo-recorder',
      reason: 'Recorder finished its handoff and is no longer active.',
    })

    expect(spawned.type).toBe('worker.spawned')
    expect(stopped.type).toBe('worker.stopped')

    const events = bus.listRecentEvents(2)
    expect(events.map((event) => event.type)).toEqual(['worker.spawned', 'worker.stopped'])
  })

  test('persists spawn requests through the JSON store path', () => {
    const fs = createMemoryFs()
    const storagePath = '/virtual/workflow-bus.json'

    const firstBus = createWorkflowBus({ storagePath, fileSystem: fs })
    const request = firstBus.appendSpawnRequest({
      runId: 'demo-5',
      askedBy: 'planner',
      scope: 'shared state',
      text: 'Does the store survive a fresh process?',
      requestedRole: 'worker',
    })

    const secondBus = createWorkflowBus({ storagePath, fileSystem: fs })

    expect(secondBus.listOpenSpawnRequests()).toHaveLength(1)
    expect(secondBus.listOpenSpawnRequests()[0]?.requestId).toBe(request.requestId)
    expect(secondBus.listRecentEvents(1)[0]?.type).toBe('spawn_request.created')
  })

  test('stores user questions in the shared ledger and emits user-question events', () => {
    const bus = makeBus()

    const question = bus.appendUserQuestion({
      runId: 'demo-question',
      askedBy: 'planner',
      scope: 'deployment target',
      text: 'Which environment should this workflow target?',
      context: 'The planner is blocked until the user chooses staging or production.',
      priority: 'blocking',
      tags: ['planner', 'user-input'],
    })

    expect(question.status).toBe('open')
    expect(question.priority).toBe('blocking')
    expect(bus.listOpenUserQuestions()).toHaveLength(1)
    expect(bus.listOpenUserQuestions()[0]?.questionId).toBe(question.questionId)

    const [event] = bus.listRecentEvents(1)
    expect(event?.type).toBe('user_question.created')
    expect(event?.payload).toMatchObject({
      questionId: question.questionId,
      askedBy: 'planner',
      priority: 'blocking',
    })
  })

  test('answering a user question marks it answered, records the answer, and drops it from the open list', () => {
    const bus = makeBus()

    const question = bus.appendUserQuestion({
      runId: 'demo-question',
      askedBy: 'planner',
      scope: 'deployment target',
      text: 'Which environment should this workflow target?',
      priority: 'blocking',
    })

    const answered = bus.answerUserQuestion({
      questionId: question.questionId,
      answeredBy: 'user',
      answerText: 'Target staging for now.',
    })

    expect(answered.status).toBe('answered')
    expect(answered.answeredBy).toBe('user')
    expect(answered.answerText).toBe('Target staging for now.')
    expect(answered.answeredAt).toEqual(expect.any(String))

    // Answered is no longer "open" — this is what lets orchestrator recovery
    // resume for the run — but it's still visible via listUserQuestions so a
    // later planner can discover the answer.
    expect(bus.listOpenUserQuestions()).toHaveLength(0)
    expect(bus.listUserQuestions()).toHaveLength(1)
    expect(bus.listUserQuestions()[0]?.answerText).toBe('Target staging for now.')

    const [event] = bus.listRecentEvents(1)
    expect(event?.type).toBe('user_question.answered')
    expect(event?.payload).toMatchObject({
      questionId: question.questionId,
      answeredBy: 'user',
      answerText: 'Target staging for now.',
    })
  })

  test('answerUserQuestion throws for an unknown questionId', () => {
    const bus = makeBus()

    expect(() =>
      bus.answerUserQuestion({
        questionId: 'does-not-exist',
        answeredBy: 'user',
        answerText: 'irrelevant',
      })
    ).toThrow('Unknown user question: does-not-exist')
  })
})
