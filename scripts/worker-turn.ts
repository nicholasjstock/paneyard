import {
  planWorkflowIteration,
  publishPlannerJobs,
  type DemoScenario,
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
}

export type WorkerTurnResult = {
  plan: PlanWorkflowIterationResult
  jobs: PlannerBusJob[]
  plannerWorker: WorkflowWorkerRecord | null
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

  const plannerWorker = args.workerRuntime
    ? args.workerRuntime.spawnWorker({
        runId: args.runId,
        role: 'planner',
        nickname: `planner-${args.nickname}-${Date.now()}`,
        reason: `Reasoning follow-up for ${args.nickname}'s reported result.`,
        scope: args.scope,
        prompt: buildPlannerPrompt(args),
      })
    : null

  return { plan, jobs, plannerWorker }
}
