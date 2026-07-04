import {
  buildPendingSpawnKeys,
  planWorkflowIteration,
  publishPlannerJobs,
  type DemoScenario,
  type OrchestratorDecisionState,
  type PlanWorkflowIterationArgs,
  type PlanWorkflowIterationResult,
  type PlannerBusJob,
} from './workflow-mcp'
import type { WorkflowBus } from './workflow-bus'
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
  bus: Parameters<typeof publishPlannerJobs>[0] & Pick<WorkflowBus, 'listRunStatuses' | 'listSpawnRequests' | 'listUserQuestions'>
  planner?: (args: PlanWorkflowIterationArgs) => PlanWorkflowIterationResult
  workerRuntime?: WorkerTurnWorkerRuntime
  previousState?: OrchestratorDecisionState
  now?: Date
}

export type WorkerTurnResult = {
  plan: PlanWorkflowIterationResult
  jobs: PlannerBusJob[]
  plannerWorker: WorkflowWorkerRecord | null
  nextState: OrchestratorDecisionState
}

function buildPlannerPrompt(args: WorkerTurnArgs): string {
  return [
    `Worker ${args.nickname} (role ${args.role}) reported this result for run ${args.runId}, scope ${args.scope}:`,
    args.result,
    'Inspect the current workflow context and decide whether additional or refined next steps are needed. If so, publish them with planner_turn. If blocked on a user decision, call append_user_question.',
  ].join('\n')
}

export function runWorkerTurn(args: WorkerTurnArgs): WorkerTurnResult {
  const planner = args.planner ?? planWorkflowIteration
  const plan = planner({
    task: args.task,
    scenario: args.scenario,
    frontendUrl: args.frontendUrl,
    verifierFinding: args.result,
  })
  const jobs = publishPlannerJobs(args.bus, {
    runId: args.runId,
    summary: plan.summary,
    plan,
  })

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
          prompt: buildPlannerPrompt(args),
        })
      : null

  const previousState = args.previousState
  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    // phase / tickCount / lastStallFinding are owned by the orchestrator-turn
    // decision loop, not by worker_turn — carry them forward untouched so a
    // worker completion can never clobber orchestrator-observed state.
    phase: previousState?.phase ?? 'starting',
    tickCount: previousState?.tickCount ?? 0,
    lastStallFinding: previousState?.lastStallFinding ?? null,
    lastPlanSummary: plan.summary,
    pendingSpawnKeys: [...new Set([...(previousState?.pendingSpawnKeys ?? []), ...buildPendingSpawnKeys(args.runId, jobs)])],
    recommendedNextSteps: plan.steps,
    lastUpdatedAt: (args.now ?? new Date()).toISOString(),
  }

  return { plan, jobs, plannerWorker, nextState }
}
