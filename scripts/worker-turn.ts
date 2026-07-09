import {
  type DemoScenario,
  type OrchestratorDecisionState,
} from './workflow-mcp'
import type { WorkflowManagedRole } from './workflow-worker-runtime'

export type WorkerTurnBus = {
  appendSpawnRequest: (args: {
    runId: string
    askedBy: string
    scope: string
    text: string
    context?: string
    requestedRole: string
    priority?: 'advisory' | 'blocking'
    tags?: string[]
  }) => Promise<{ requestId: string }>
  listSpawnRequests?: () => Promise<Array<{
    requestId: string
    runId: string
    askedBy: string
    scope: string
    requestedRole: string
    status: 'open' | 'fulfilled' | 'dismissed'
    fulfilledWorkerId?: string | null
  }>>
}

export type WorkerTurnArgs = {
  runId: string
  role: WorkflowManagedRole
  nickname: string
  scope: string
  result: string
  task: string
  scenario: DemoScenario
  frontendUrl: string
  bus: WorkerTurnBus
  // workerIds currently active for this run — lets a stale fulfilled
  // follow-up request (its planner already stopped) be told apart from one
  // that's still in flight. See the dedup comment below.
  activeWorkerIds?: ReadonlySet<string>
  previousState?: OrchestratorDecisionState
  now?: Date
}

export type WorkerTurnResult = {
  // The bus request asking the supervisor to spawn a follow-up planner —
  // reused rather than duplicated if an equivalent request already exists
  // (open or fulfilled). The supervisor (not worker_turn) is what actually
  // spawns the process, on its next tick, exactly like every other worker
  // spawn in the system.
  plannerRequest: { requestId: string }
  nextState: OrchestratorDecisionState
}

const PLANNER_FOLLOWUP_SCOPE = 'workflow-plan.md'

export async function runWorkerTurn(args: WorkerTurnArgs): Promise<WorkerTurnResult> {
  const previousState = args.previousState
  const followingSteps = previousState?.followingSteps ?? []

  const activeWorkerIds = args.activeWorkerIds ?? new Set<string>()

  // A follow-up planner request is a repeatable recovery ask, not a
  // one-time artifact — an 'open' request is safe to reuse unconditionally
  // (still pending), but a 'fulfilled' one only still represents "already
  // being handled" while the planner it spawned is still active. Once that
  // planner has stopped, a later, different worker's own worker_turn call
  // must not silently reuse the old, already-resolved request — that would
  // mean only the very first follow-up planner in a run's lifetime ever
  // gets asked for.
  const existingRequests = await args.bus.listSpawnRequests?.()
  const existingRequest = existingRequests?.find((request) => {
    if (
      request.status === 'dismissed' ||
      request.runId !== args.runId ||
      request.requestedRole !== 'planner' ||
      request.scope !== PLANNER_FOLLOWUP_SCOPE
    ) {
      return false
    }

    if (request.status === 'open') {
      return true
    }

    return Boolean(request.fulfilledWorkerId && activeWorkerIds.has(request.fulfilledWorkerId))
  })

  const plannerRequest =
    existingRequest ??
    (await args.bus.appendSpawnRequest({
      runId: args.runId,
      askedBy: 'worker',
      scope: PLANNER_FOLLOWUP_SCOPE,
      text: 'Decide the next nextStep (usually the head of followingSteps, but reconsider it against the reported result) and the new followingSteps, then publish them with planner_turn. If blocked on a user decision, call append_user_question.',
      context: [
        `Worker ${args.nickname} (role ${args.role}) reported this result for run ${args.runId}, scope ${args.scope}: ${args.result}`,
        `Current followingSteps queue (JSON, decided by the previous planner_turn call): ${JSON.stringify(followingSteps)}`,
      ].join(' '),
      requestedRole: 'planner',
      priority: 'blocking',
      tags: ['planner', PLANNER_FOLLOWUP_SCOPE, 'worker-turn-followup'],
    }))

  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    // phase / tickCount / lastPlanSummary / lastStallFinding / followingSteps
    // are all owned by planner_turn (the sole publisher of decisions) and
    // orchestrator-turn's stall detection — worker_turn only requests the
    // follow-up planner and reports what it saw, so it must carry all of
    // this forward untouched rather than guessing at a new value itself.
    phase: previousState?.phase ?? 'starting',
    tickCount: previousState?.tickCount ?? 0,
    lastStallFinding: previousState?.lastStallFinding ?? null,
    lastPlanSummary: previousState?.lastPlanSummary ?? null,
    pendingSpawnKeys: previousState?.pendingSpawnKeys ?? [],
    followingSteps,
    lastUpdatedAt: (args.now ?? new Date()).toISOString(),
  }

  return { plannerRequest, nextState }
}
