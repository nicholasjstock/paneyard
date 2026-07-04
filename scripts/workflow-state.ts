import type { WorkflowBus } from './workflow-bus'
import type { WorkflowWorkerRecord } from './workflow-worker-runtime'

export type WorkflowServerState = {
  generatedAt: string
  runStatuses: Array<{
    runId: string
    phase: string
    owner: string
    summary: string
    at: string
  }>
  workers: WorkflowWorkerRecord[]
  openSpawnRequests: Array<{
    requestId: string
    runId: string
    askedBy: string
    askedAt: string
    scope: string
    text: string
    context: string | null
    requestedRole: string
    priority: 'advisory' | 'blocking'
    status: 'open' | 'fulfilled' | 'dismissed'
    fulfilledBy: string | null
    fulfilledAt: string | null
    fulfillmentNote: string | null
    tags: string[]
  }>
  openUserQuestions: Array<{
    questionId: string
    runId: string
    askedBy: string
    askedAt: string
    scope: string
    text: string
    context: string | null
    priority: 'advisory' | 'blocking'
    status: 'open' | 'dismissed'
    tags: string[]
  }>
  recentEvents: Array<{
    eventId: string
    at: string
    type: string
    payload: Record<string, unknown>
  }>
}

export type WorkflowWorkerLog = {
  workerId: string
  runId: string
  role: string
  nickname: string
  status: string
  logPath: string
  lastMessagePath: string
  startedAt: string
  stoppedAt: string | null
  stopReason: string | null
  tail: string | null
  lastMessage: string | null
  logContent: string | null
  logTruncated: boolean
  logTotalBytes: number
}

export type WorkflowBusSnapshotSource = Pick<
  WorkflowBus,
  'listRunStatuses' | 'listOpenSpawnRequests' | 'listOpenUserQuestions' | 'listRecentEvents'
>

export type WorkflowWorkerRuntimeSnapshotSource = {
  listWorkers: (args?: { runId?: string; activeOnly?: boolean }) => WorkflowWorkerRecord[]
}

export function collectWorkflowServerState(args: {
  bus: WorkflowBusSnapshotSource
  workerRuntime: WorkflowWorkerRuntimeSnapshotSource
}): WorkflowServerState {
  return {
    generatedAt: new Date().toISOString(),
    runStatuses: args.bus.listRunStatuses(),
    workers: args.workerRuntime.listWorkers(),
    openSpawnRequests: args.bus.listOpenSpawnRequests(),
    openUserQuestions: args.bus.listOpenUserQuestions(),
    recentEvents: args.bus.listRecentEvents(25),
  }
}
