import {
  buildPendingSpawnKeys,
  publishPlannerJobs,
  type OrchestratorDecisionState,
  type PlannerBusJob,
  type WorkflowStep,
} from './workflow-mcp'

export type PlannerTurnArgs = {
  runId: string
  summary: string
  nextStep: WorkflowStep | null
  followingSteps: WorkflowStep[]
  bus: Parameters<typeof publishPlannerJobs>[0]
  previousState?: OrchestratorDecisionState
  now?: Date
}

export type PlannerTurnResult = {
  jobs: PlannerBusJob[]
  nextState: OrchestratorDecisionState
}

export function runPlannerTurn(args: PlannerTurnArgs): PlannerTurnResult {
  const jobs = publishPlannerJobs(args.bus, {
    runId: args.runId,
    summary: args.summary,
    plan: { summary: args.summary, nextStep: args.nextStep, followingSteps: args.followingSteps },
  })

  const previousState = args.previousState
  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    phase: jobs.length > 0 ? 'planning' : previousState?.phase ?? 'starting',
    tickCount: (previousState?.tickCount ?? 0) + 1,
    lastPlanSummary: args.summary,
    pendingSpawnKeys: [...new Set([...(previousState?.pendingSpawnKeys ?? []), ...buildPendingSpawnKeys(args.runId, jobs)])],
    // The followingSteps queue this planner decided — the source of truth
    // for the *next* planner invocation (after this step's worker reports,
    // or on the next stall) to pick up where this one left off.
    followingSteps: args.followingSteps,
    lastStallFinding: previousState?.lastStallFinding ?? null,
    lastUpdatedAt: (args.now ?? new Date()).toISOString(),
  }

  return { jobs, nextState }
}
