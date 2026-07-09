export type WorkflowSpawnRequestPriority = 'advisory' | 'blocking'
export type WorkflowSpawnRequestStatus = 'open' | 'fulfilled' | 'dismissed'
export type WorkflowUserQuestionPriority = 'advisory' | 'blocking'
export type WorkflowUserQuestionStatus = 'open' | 'answered' | 'dismissed'

export type WorkflowSpawnRequest = {
  requestId: string
  runId: string
  askedBy: string
  askedAt: string
  scope: string
  text: string
  context: string | null
  requestedRole: string
  priority: WorkflowSpawnRequestPriority
  status: WorkflowSpawnRequestStatus
  fulfilledBy: string | null
  fulfilledAt: string | null
  fulfillmentNote: string | null
  // workerId of the worker spawned to fulfill this request, if fulfillment
  // happened by spawning one. Dependents wait for that worker to actually
  // stop, not merely for this request to be marked fulfilled (fulfillment
  // fires at spawn time, before the worker has done any work).
  fulfilledWorkerId: string | null
  dismissedBy: string | null
  dismissedAt: string | null
  dismissalNote: string | null
  tags: string[]
}

export type WorkflowBusEvent = {
  eventId: string
  at: string
  type: string
  payload: Record<string, unknown>
}

export type WorkflowUserQuestion = {
  questionId: string
  runId: string
  askedBy: string
  askedAt: string
  scope: string
  text: string
  context: string | null
  priority: WorkflowUserQuestionPriority
  status: WorkflowUserQuestionStatus
  tags: string[]
  answeredBy: string | null
  answeredAt: string | null
  answerText: string | null
}

export type WorkflowRunStatus = {
  runId: string
  phase: string
  owner: string
  summary: string
  at: string
}

export type WorkflowWorkerLifecycleEvent = {
  runId: string
  owner: string
  role: string
  nickname: string
  reason: string
}

type AppendSpawnRequestArgs = {
  runId: string
  askedBy: string
  scope: string
  text: string
  context?: string
  requestedRole: string
  priority?: WorkflowSpawnRequestPriority
  tags?: string[]
}

type AppendUserQuestionArgs = {
  runId: string
  askedBy: string
  scope: string
  text: string
  context?: string
  priority?: WorkflowUserQuestionPriority
  tags?: string[]
}

type FulfillSpawnRequestArgs = {
  requestId: string
  fulfilledBy: string
  fulfillmentNote: string
  fulfilledWorkerId?: string
}

type DismissSpawnRequestArgs = {
  requestId: string
  dismissedBy: string
  dismissalNote: string
}

type AnswerUserQuestionArgs = {
  questionId: string
  answeredBy: string
  answerText: string
}

type PublishRunStatusArgs = {
  runId: string
  phase: string
  owner: string
  summary: string
}

type PublishWorkerLifecycleEventArgs = {
  runId: string
  owner: string
  role: string
  nickname: string
  reason: string
}

// Satisfied by workflow-bus-rails.ts's createRailsWorkflowBus -- the only
// implementation now that the JSON-file backend has been retired (see
// EXTRACTION_HANDOFF history / the JSON-bus-to-Rails migration plan).
export type WorkflowBus = {
  publishRunStatus: (args: PublishRunStatusArgs) => Promise<WorkflowRunStatus>
  appendSpawnRequest: (args: AppendSpawnRequestArgs) => Promise<WorkflowSpawnRequest>
  appendUserQuestion: (args: AppendUserQuestionArgs) => Promise<WorkflowUserQuestion>
  answerUserQuestion: (args: AnswerUserQuestionArgs) => Promise<WorkflowUserQuestion>
  fulfillSpawnRequest: (args: FulfillSpawnRequestArgs) => Promise<WorkflowSpawnRequest>
  dismissSpawnRequest: (args: DismissSpawnRequestArgs) => Promise<WorkflowSpawnRequest>
  listRunStatuses: () => Promise<WorkflowRunStatus[]>
  listOpenSpawnRequests: () => Promise<WorkflowSpawnRequest[]>
  listSpawnRequests: () => Promise<WorkflowSpawnRequest[]>
  listOpenUserQuestions: () => Promise<WorkflowUserQuestion[]>
  listUserQuestions: () => Promise<WorkflowUserQuestion[]>
  listRecentEvents: (limit?: number) => Promise<WorkflowBusEvent[]>
  // In-process pub/sub only, satisfied as a no-op by the Rails-backed
  // implementation -- Rails broadcasts live updates via Turbo Streams
  // instead (see ops/app/models/bus_event.rb).
  subscribe: (listener: (event: WorkflowBusEvent) => void) => () => void
  publishWorkerSpawned: (args: PublishWorkerLifecycleEventArgs) => Promise<WorkflowBusEvent>
  publishWorkerStopped: (args: PublishWorkerLifecycleEventArgs) => Promise<WorkflowBusEvent>
}
