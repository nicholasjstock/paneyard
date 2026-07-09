import * as fs from 'fs'

import { appendWorkerLogLine, createId, describeWorkerExit, spawnWorkerProcess } from '../../workflow-worker-spawn'
import type {
  WorkflowBus,
  WorkflowBusEvent,
  WorkflowRunStatus,
  WorkflowSpawnRequest,
  WorkflowUserQuestion,
} from '../../workflow-bus'
import type {
  ListWorkersArgs,
  SpawnWorkerArgs,
  StopWorkerArgs,
  WorkerDriver,
  WorkerProcessAdapter,
  WorkflowWorkerRecord,
  WorkflowWorkerRuntime,
} from '../../workflow-worker-runtime'
import { formatWorkflowWorkerLifecycleLine } from '../../workflow-worker-logging'
import type { WorkerSpawnFileSystem } from '../../workflow-worker-spawn'

// In-memory stand-ins for WorkflowBus/WorkflowWorkerRuntime, used across the
// test suite wherever a test previously constructed the now-retired
// JSON-file-backed createWorkflowBus/createWorkflowWorkerRuntime purely to
// get a fresh, isolated instance per test -- these tests never cared about
// JSON persistence itself, just about having *some* real implementation of
// the interface to exercise orchestrator-turn.ts/planner-turn.ts/worker-turn.ts/
// supervisor-loop.ts against. No network or filesystem-JSON round-trip
// needed to satisfy that.

function cloneSpawnRequest(request: WorkflowSpawnRequest): WorkflowSpawnRequest {
  return { ...request, tags: [...request.tags] }
}

function cloneUserQuestion(question: WorkflowUserQuestion): WorkflowUserQuestion {
  return { ...question, tags: [...question.tags] }
}

export function createFakeWorkflowBus(): WorkflowBus {
  const spawnRequests = new Map<string, WorkflowSpawnRequest>()
  const userQuestions = new Map<string, WorkflowUserQuestion>()
  const events: WorkflowBusEvent[] = []
  const runStatuses = new Map<string, WorkflowRunStatus>()
  const listeners = new Set<(event: WorkflowBusEvent) => void>()

  const emit = (type: string, payload: Record<string, unknown>): WorkflowBusEvent => {
    const event: WorkflowBusEvent = { eventId: createId(), at: new Date().toISOString(), type, payload }
    events.push(event)
    for (const listener of listeners) listener(event)
    return event
  }

  return {
    async publishRunStatus(args) {
      const status: WorkflowRunStatus = { ...args, at: new Date().toISOString() }
      runStatuses.set(status.runId, status)
      emit('run.status', status)
      return { ...status }
    },

    async appendSpawnRequest(args) {
      const request: WorkflowSpawnRequest = {
        requestId: createId(),
        runId: args.runId,
        askedBy: args.askedBy,
        askedAt: new Date().toISOString(),
        scope: args.scope,
        text: args.text,
        context: args.context ?? null,
        requestedRole: args.requestedRole,
        priority: args.priority ?? 'advisory',
        status: 'open',
        fulfilledBy: null,
        fulfilledAt: null,
        fulfillmentNote: null,
        fulfilledWorkerId: null,
        dismissedBy: null,
        dismissedAt: null,
        dismissalNote: null,
        tags: [...(args.tags ?? [])],
      }
      spawnRequests.set(request.requestId, request)
      emit('spawn_request.created', {
        requestId: request.requestId,
        runId: request.runId,
        askedBy: request.askedBy,
        scope: request.scope,
        requestedRole: request.requestedRole,
        priority: request.priority,
        context: request.context,
        tags: request.tags,
      })
      return cloneSpawnRequest(request)
    },

    async appendUserQuestion(args) {
      const question: WorkflowUserQuestion = {
        questionId: createId(),
        runId: args.runId,
        askedBy: args.askedBy,
        askedAt: new Date().toISOString(),
        scope: args.scope,
        text: args.text,
        context: args.context ?? null,
        priority: args.priority ?? 'advisory',
        status: 'open',
        tags: [...(args.tags ?? [])],
        answeredBy: null,
        answeredAt: null,
        answerText: null,
      }
      userQuestions.set(question.questionId, question)
      emit('user_question.created', {
        questionId: question.questionId,
        runId: question.runId,
        askedBy: question.askedBy,
        scope: question.scope,
        priority: question.priority,
        context: question.context,
        tags: question.tags,
      })
      return cloneUserQuestion(question)
    },

    async answerUserQuestion({ questionId, answeredBy, answerText }) {
      const question = userQuestions.get(questionId)
      if (!question) throw new Error(`Unknown user question: ${questionId}`)
      question.status = 'answered'
      question.answeredBy = answeredBy
      question.answeredAt = new Date().toISOString()
      question.answerText = answerText
      emit('user_question.answered', { questionId, runId: question.runId, answeredBy, answerText })
      return cloneUserQuestion(question)
    },

    async fulfillSpawnRequest({ requestId, fulfilledBy, fulfillmentNote, fulfilledWorkerId }) {
      const request = spawnRequests.get(requestId)
      if (!request) throw new Error(`Unknown spawn request: ${requestId}`)
      request.status = 'fulfilled'
      request.fulfilledBy = fulfilledBy
      request.fulfilledAt = new Date().toISOString()
      request.fulfillmentNote = fulfillmentNote
      request.fulfilledWorkerId = fulfilledWorkerId ?? null
      emit('spawn_request.fulfilled', {
        requestId,
        runId: request.runId,
        fulfilledBy,
        fulfillmentNote,
        fulfilledWorkerId: request.fulfilledWorkerId,
      })
      return cloneSpawnRequest(request)
    },

    async dismissSpawnRequest({ requestId, dismissedBy, dismissalNote }) {
      const request = spawnRequests.get(requestId)
      if (!request) throw new Error(`Unknown spawn request: ${requestId}`)
      request.status = 'dismissed'
      request.dismissedBy = dismissedBy
      request.dismissedAt = new Date().toISOString()
      request.dismissalNote = dismissalNote
      emit('spawn_request.dismissed', { requestId, runId: request.runId, dismissedBy, dismissalNote })
      return cloneSpawnRequest(request)
    },

    async publishWorkerSpawned(args) {
      return emit('worker.spawned', { ...args })
    },

    async publishWorkerStopped(args) {
      return emit('worker.stopped', { ...args })
    },

    async listRunStatuses() {
      return [...runStatuses.values()].map((status) => ({ ...status }))
    },

    async listOpenSpawnRequests() {
      return [...spawnRequests.values()].filter((request) => request.status === 'open').map(cloneSpawnRequest)
    },

    async listSpawnRequests() {
      return [...spawnRequests.values()].map(cloneSpawnRequest)
    },

    async listOpenUserQuestions() {
      return [...userQuestions.values()].filter((question) => question.status === 'open').map(cloneUserQuestion)
    },

    async listUserQuestions() {
      return [...userQuestions.values()].map(cloneUserQuestion)
    },

    async listRecentEvents(limit = 20) {
      return events.slice(-limit)
    },

    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}

export type CreateFakeWorkerRuntimeArgs = {
  rootDir: string
  outputDir: string
  fileSystem?: WorkerSpawnFileSystem
  processAdapter: WorkerProcessAdapter
  workerDriver?: WorkerDriver
  // Lets a test seed pre-existing worker records (e.g. a worker that's
  // already "running" before the code under test ever calls spawnWorker) --
  // replaces what tests used to do by writing workers.json directly.
  initialWorkers?: WorkflowWorkerRecord[]
}

function resolvePath(baseDir: string, suffix: string): string {
  return `${baseDir.replace(/\/$/, '')}/${suffix}`
}

function cloneWorker(worker: WorkflowWorkerRecord): WorkflowWorkerRecord {
  return { ...worker, args: [...worker.args] }
}

export function createFakeWorkflowWorkerRuntime(args: CreateFakeWorkerRuntimeArgs): WorkflowWorkerRuntime {
  const processAdapter = args.processAdapter
  const workerDriver: WorkerDriver = args.workerDriver ?? 'codex'
  const workersDir = resolvePath(args.outputDir, 'workers')
  const workers: WorkflowWorkerRecord[] = (args.initialWorkers ?? []).map(cloneWorker)

  const fileSystem: WorkerSpawnFileSystem =
    args.fileSystem ??
    {
      writeFileSync: (filePath, content) => fs.writeFileSync(filePath, content),
      appendFileSync: (filePath, content) => fs.appendFileSync(filePath, content),
      readFileSync: (filePath, encoding = 'utf8') => fs.readFileSync(filePath, encoding),
      existsSync: (filePath) => fs.existsSync(filePath),
    }

  const ensureDir = () => {
    fs.mkdirSync(args.outputDir, { recursive: true })
    fs.mkdirSync(workersDir, { recursive: true })
  }

  const refreshWorkers = () => {
    for (const worker of workers) {
      if (worker.status !== 'running' || processAdapter.isAlive(worker.pid)) continue

      worker.status = 'stopped'
      worker.stoppedAt = new Date().toISOString()
      worker.stopReason =
        worker.stopReason ?? describeWorkerExit(fileSystem, worker, processAdapter.getExitStatus?.(worker.pid) ?? null)
      appendWorkerLogLine(
        fileSystem,
        worker.logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: worker.stoppedAt,
          event: 'stopped',
          workerId: worker.workerId,
          runId: worker.runId,
          role: worker.role,
          nickname: worker.nickname,
          pid: worker.pid,
          scope: worker.scope,
          reason: worker.reason,
          command: worker.command,
          status: worker.status,
          stopReason: worker.stopReason,
        })
      )
    }
  }

  const findWorker = (stopArgs: StopWorkerArgs) =>
    workers.find((worker) => ('workerId' in stopArgs ? worker.workerId === stopArgs.workerId : worker.nickname === stopArgs.nickname))

  return {
    async spawnWorker(spawnArgs: SpawnWorkerArgs) {
      ensureDir()
      const worker = spawnWorkerProcess(
        { rootDir: args.rootDir, workersDir, workerDriver, fileSystem, processAdapter },
        spawnArgs
      )
      workers.push(worker)
      return cloneWorker(worker)
    },

    async listWorkers(listArgs: ListWorkersArgs = {}) {
      refreshWorkers()
      return workers
        .filter((worker) => (listArgs.runId ? worker.runId === listArgs.runId : true))
        .filter((worker) => (listArgs.activeOnly ? worker.status === 'running' : true))
        .map(cloneWorker)
    },

    async stopWorker(stopArgs: StopWorkerArgs) {
      refreshWorkers()
      const worker = findWorker(stopArgs)
      if (!worker) {
        throw new Error(
          'workerId' in stopArgs ? `Unknown worker: ${stopArgs.workerId}` : `Unknown worker nickname: ${stopArgs.nickname}`
        )
      }

      if (worker.status === 'running' && processAdapter.isAlive(worker.pid)) {
        processAdapter.kill(worker.pid, 'SIGTERM')
      }

      worker.status = 'stopped'
      worker.stoppedAt = new Date().toISOString()
      worker.stopReason = stopArgs.reason
      appendWorkerLogLine(
        fileSystem,
        worker.logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: worker.stoppedAt,
          event: 'stopped',
          workerId: worker.workerId,
          runId: worker.runId,
          role: worker.role,
          nickname: worker.nickname,
          pid: worker.pid,
          scope: worker.scope,
          reason: worker.reason,
          command: worker.command,
          status: worker.status,
          stopReason: worker.stopReason,
        })
      )
      return cloneWorker(worker)
    },
  }
}
