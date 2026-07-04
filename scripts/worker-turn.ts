import {
  type DemoScenario,
  type OrchestratorDecisionState,
  type WorkflowStep,
} from './workflow-mcp'
import type { WorkflowManagedRole, WorkflowWorkerRecord } from './workflow-worker-runtime'

export type WorkerTurnWorkerRuntime = {
  spawnWorker: (args: {
    runId: string
    role: WorkflowManagedRole
    nickname: string
    reason: string
    scope: string
    prompt: string
  }) => WorkflowWorkerRecord
  listWorkers?: (args?: { runId?: string; activeOnly?: boolean }) => WorkflowWorkerRecord[]
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
  workerRuntime?: WorkerTurnWorkerRuntime
  previousState?: OrchestratorDecisionState
  now?: Date
}

export type WorkerTurnResult = {
  plannerWorker: WorkflowWorkerRecord | null
  nextState: OrchestratorDecisionState
}

function buildPlannerPrompt(args: WorkerTurnArgs, followingSteps: WorkflowStep[]): string {
  return [
    `Worker ${args.nickname} (role ${args.role}) reported this result for run ${args.runId}, scope ${args.scope}:`,
    args.result,
    `Current followingSteps queue (JSON, decided by the previous planner_turn call): ${JSON.stringify(followingSteps)}`,
    'Decide the next nextStep (usually the head of that queue, but reconsider it against the reported result) and the new followingSteps, then publish them with planner_turn. If blocked on a user decision, call append_user_question.',
  ].join('\n')
}

export function runWorkerTurn(args: WorkerTurnArgs): WorkerTurnResult {
  const previousState = args.previousState
  const followingSteps = previousState?.followingSteps ?? []

  const activeWorkers = args.workerRuntime?.listWorkers?.({ runId: args.runId, activeOnly: true }) ?? []
  const plannerAlreadyActive = activeWorkers.some((worker) => worker.role === 'planner')

  const plannerWorker =
    args.workerRuntime && !plannerAlreadyActive
      ? args.workerRuntime.spawnWorker({
          runId: args.runId,
          role: 'planner',
          nickname: `planner-${args.nickname}-${Date.now()}`,
          reason: `Reasoning follow-up for ${args.nickname}'s reported result.`,
          scope: args.scope,
          prompt: buildPlannerPrompt(args, followingSteps),
        })
      : null

  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    // phase / tickCount / lastPlanSummary / lastStallFinding / followingSteps
    // are all owned by planner_turn (the sole publisher of decisions) and
    // orchestrator-turn's stall detection — worker_turn only spawns the
    // planner and reports what it saw, so it must carry all of this forward
    // untouched rather than guessing at a new value itself.
    phase: previousState?.phase ?? 'starting',
    tickCount: previousState?.tickCount ?? 0,
    lastStallFinding: previousState?.lastStallFinding ?? null,
    lastPlanSummary: previousState?.lastPlanSummary ?? null,
    pendingSpawnKeys: previousState?.pendingSpawnKeys ?? [],
    followingSteps,
    lastUpdatedAt: (args.now ?? new Date()).toISOString(),
  }

  return { plannerWorker, nextState }
}
