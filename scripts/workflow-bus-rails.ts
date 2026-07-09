import { railsGet, railsPatch, railsPost, type RailsApiRequestOptions } from './rails-api-client'
import type { WorkflowBus, WorkflowBusEvent, WorkflowRunStatus, WorkflowSpawnRequest, WorkflowUserQuestion } from './workflow-bus'

export type WorkflowBusRailsOptions = RailsApiRequestOptions

// HTTP-backed implementation of WorkflowBus (workflow-bus.ts), satisfying
// the exact same type. Every write maps onto one of the Api:: controllers
// in ops/ (SpawnRequestsController, UserQuestionsController,
// RunStatusesController); every list maps onto that controller's #index.
export function createRailsWorkflowBus(options: WorkflowBusRailsOptions = {}): WorkflowBus {
  return {
    async publishRunStatus(args) {
      return railsPatch<WorkflowRunStatus>('/api/run_status', args, options)
    },

    async appendSpawnRequest(args) {
      return railsPost<WorkflowSpawnRequest>('/api/spawn_requests', args, options)
    },

    async appendUserQuestion(args) {
      return railsPost<WorkflowUserQuestion>('/api/user_questions', args, options)
    },

    async answerUserQuestion({ questionId, answeredBy, answerText }) {
      return railsPost<WorkflowUserQuestion>(
        `/api/user_questions/${encodeURIComponent(questionId)}/answer`,
        { answeredBy, answerText },
        options
      )
    },

    async fulfillSpawnRequest({ requestId, fulfilledBy, fulfillmentNote, fulfilledWorkerId }) {
      return railsPost<WorkflowSpawnRequest>(
        `/api/spawn_requests/${encodeURIComponent(requestId)}/fulfill`,
        { fulfilledBy, fulfillmentNote, fulfilledWorkerId },
        options
      )
    },

    async dismissSpawnRequest({ requestId, dismissedBy, dismissalNote }) {
      return railsPost<WorkflowSpawnRequest>(
        `/api/spawn_requests/${encodeURIComponent(requestId)}/dismiss`,
        { dismissedBy, dismissalNote },
        options
      )
    },

    async listRunStatuses() {
      return railsGet<WorkflowRunStatus[]>('/api/run_statuses', undefined, options)
    },

    async listOpenSpawnRequests() {
      return railsGet<WorkflowSpawnRequest[]>('/api/spawn_requests', { status: 'open' }, options)
    },

    async listSpawnRequests() {
      return railsGet<WorkflowSpawnRequest[]>('/api/spawn_requests', undefined, options)
    },

    async listOpenUserQuestions() {
      return railsGet<WorkflowUserQuestion[]>('/api/user_questions', { status: 'open' }, options)
    },

    async listUserQuestions() {
      return railsGet<WorkflowUserQuestion[]>('/api/user_questions', undefined, options)
    },

    async listRecentEvents(limit) {
      const result = await railsGet<{ events: WorkflowBusEvent[] }>('/api/events', { limit }, options)
      return result.events
    },

    // In-process pub/sub only, per WorkflowBus.subscribe's own type
    // comment — nothing on the Rails side drives this; BusEvent broadcasts
    // Turbo Streams directly instead (see ops/app/models/bus_event.rb).
    // Kept as a working no-op so the type is satisfied.
    subscribe(_listener) {
      return () => {}
    },

    // No-op: POST /api/workers (called from workflow-worker-runtime-rails.ts's
    // spawnWorker) already creates the matching worker.spawned BusEvent as
    // a model callback server-side — an explicit publish here would just
    // be a redundant round-trip for something that already happened.
    // Returns a locally-synthesized event so the return type still holds
    // for any caller that inspects it.
    async publishWorkerSpawned(args) {
      return synthesizeWorkerEvent('worker.spawned', args)
    },

    async publishWorkerStopped(args) {
      return synthesizeWorkerEvent('worker.stopped', args)
    },
  }
}

function synthesizeWorkerEvent(
  type: string,
  args: { runId: string; owner: string; role: string; nickname: string; reason: string }
): WorkflowBusEvent {
  return {
    eventId: `local-${type}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    at: new Date().toISOString(),
    type,
    payload: { ...args },
  }
}
