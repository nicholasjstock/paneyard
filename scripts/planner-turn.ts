import {
  publishPlannerJobs,
  type PlannerBusJob,
  type WorkflowStep,
} from './workflow-mcp'

export type PlannerTurnArgs = {
  runId: string
  summary: string
  steps: WorkflowStep[]
  bus: Parameters<typeof publishPlannerJobs>[0]
}

export type PlannerTurnResult = {
  jobs: PlannerBusJob[]
}

export function runPlannerTurn(args: PlannerTurnArgs): PlannerTurnResult {
  const jobs = publishPlannerJobs(args.bus, {
    runId: args.runId,
    summary: args.summary,
    plan: { summary: args.summary, steps: args.steps },
  })

  return { jobs }
}
