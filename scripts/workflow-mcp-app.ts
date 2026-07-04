import { spawnSync } from 'child_process'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import * as path from 'path'
import { fileURLToPath } from 'url'
import * as z from 'zod/v4'

import {
  appendOrchestratorTickHistory,
  buildWorkflowContext,
  buildGuardedCommand,
  collectWorkflowState,
  listPlannerDeclaredArtifacts,
  planWorkflowIteration,
  publishPlannerJobs,
  queueLongPhoneDemoPlannerJob,
  readOrchestratorState,
  readOrchestratorTickHistory,
  readWorkflowArtifact,
  writeOrchestratorState,
  writeWorkflowArtifact,
  type GuardedCommand,
  type OrchestratorDecisionState,
  type WorkflowContext,
} from './workflow-mcp'
import { runOrchestratorTurn } from './orchestrator-turn'
import { runWorkerTurn } from './worker-turn'
import { runPlannerTurn } from './planner-turn'
import { workflowBus } from './workflow-bus'
import { formatWorkflowLogLine } from './workflow-logging'
import { createWorkflowWorkerRuntime } from './workflow-worker-runtime'
import { createNodeWorkerProcessAdapter } from './workflow-worker-runtime-node'
import { createFakeWorkerProcessAdapter } from './workflow-worker-runtime-fake'
import { collectWorkflowServerState } from './workflow-state'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// ROOT_DIR is the project being orchestrated (e.g. simple-retail-planner),
// not this package's own install location. Every real launch path sets
// WORKFLOW_TARGET_ROOT explicitly; the __dirname-based fallback only applies
// to standalone dev/test runs of this package with no target project.
export const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT
  ? path.resolve(process.env.WORKFLOW_TARGET_ROOT)
  : path.resolve(__dirname, '..')
export const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
export const OUTPUT_DIR = process.env.WORKFLOW_STATE_DIR
  ? path.resolve(process.env.WORKFLOW_STATE_DIR)
  : path.resolve(FRONT_DIR, 'demo-output', 'agents-sdk')
export const context = buildWorkflowContext({
  rootDir: ROOT_DIR,
  frontDir: FRONT_DIR,
  outputDir: OUTPUT_DIR,
})
export const workerRuntime = createWorkflowWorkerRuntime({
  rootDir: ROOT_DIR,
  outputDir: OUTPUT_DIR,
  processAdapter:
    process.env.WORKFLOW_FAKE_WORKER_SPAWN === '1'
      ? createFakeWorkerProcessAdapter(path.join(OUTPUT_DIR, 'fake-spawn-calls.json'))
      : createNodeWorkerProcessAdapter(),
})

export type GuardedCommandRunner = (spec: GuardedCommand) => {
  status: number | null
  stdout: string
  stderr: string
}

function runGuardedCommandWithSpawnSync(spec: GuardedCommand): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync(spec.command, spec.args, {
    cwd: spec.cwd,
    encoding: 'utf8',
  })

  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  }
}

export type WorkflowServerDeps = {
  bus?: typeof workflowBus
  workerRuntime?: typeof workerRuntime
  context?: WorkflowContext
  commandRunner?: GuardedCommandRunner
}

const workerRoleSchema = z.enum(['planner', 'orchestrator', 'worker'])

const workflowAgentSchema = z.enum(['orchestrator', 'worker'])

const workerRecordSchema = z.object({
  workerId: z.string(),
  runId: z.string(),
  role: workerRoleSchema,
  nickname: z.string(),
  reason: z.string(),
  scope: z.string(),
  status: z.enum(['running', 'stopped']),
  pid: z.number().int(),
  promptPath: z.string(),
  logPath: z.string(),
  lastMessagePath: z.string(),
  envPath: z.string(),
  command: z.string(),
  args: z.array(z.string()),
  startedAt: z.string(),
  stoppedAt: z.string().nullable(),
  stopReason: z.string().nullable(),
})

const workflowUserQuestionSchema = z.object({
  questionId: z.string(),
  runId: z.string(),
  askedBy: z.string(),
  askedAt: z.string(),
  scope: z.string(),
  text: z.string(),
  context: z.string().nullable(),
  priority: z.enum(['advisory', 'blocking']),
  status: z.enum(['open', 'dismissed']),
  tags: z.array(z.string()),
})

const workflowStepSchema = z.object({
  owner: z.string(),
  artifact: z.string(),
  successCheck: z.string(),
  dependsOnArtifacts: z.array(z.string()).optional(),
})

const orchestratorDecisionStateSchema = z.object({
  runId: z.string(),
  phase: z.enum(['starting', 'planning', 'waiting_on_workers', 'stalled', 'completed']),
  tickCount: z.number().int().min(0),
  lastPlanSummary: z.string().nullable(),
  pendingSpawnKeys: z.array(z.string()),
  recommendedNextSteps: z.array(workflowStepSchema),
  lastStallFinding: z.string().nullable(),
  lastUpdatedAt: z.string().nullable(),
})


function logWorkflow(scope: string, message: string, details?: Record<string, unknown>) {
  console.error(
    formatWorkflowLogLine({
      timestamp: new Date().toISOString(),
      scope,
      message,
      details,
    })
  )
}

export function createWorkflowServer(deps: WorkflowServerDeps = {}): McpServer {
  const activeBus = deps.bus ?? workflowBus
  const activeWorkerRuntime = deps.workerRuntime ?? workerRuntime
  const activeContext = deps.context ?? context
  const activeCommandRunner = deps.commandRunner ?? runGuardedCommandWithSpawnSync

  const server = new McpServer({
    name: 'simple-retail-planner-workflow',
    version: '0.1.0',
  })

  server.registerTool(
    'spawn_worker',
    {
      description: 'Spawn one MCP-managed worker process and persist observable worker state for the run.',
      inputSchema: {
        runId: z.string().min(1),
        role: workerRoleSchema,
        nickname: z.string().min(1),
        reason: z.string().min(1),
        scope: z.string().min(1),
        prompt: z.string().min(1),
      },
      outputSchema: workerRecordSchema,
    },
    async ({ runId, role, nickname, reason, scope, prompt }) => {
      logWorkflow('tool:spawn_worker', 'requested', { runId, role, nickname, scope })
      // Persona-wrapping happens inside workerRuntime.spawnWorker itself (see
      // workflow-worker-runtime.ts) so every spawn path gets it consistently,
      // not just calls that go through this specific MCP tool.
      const structuredContent = activeWorkerRuntime.spawnWorker({
        runId,
        role,
        nickname,
        reason,
        scope,
        prompt,
      })
      activeBus.publishWorkerSpawned({
        runId,
        owner: 'workflow_mcp',
        role,
        nickname,
        reason,
      })
      logWorkflow('tool:spawn_worker', 'completed', {
        runId,
        role,
        nickname,
        pid: structuredContent.pid,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'list_workers',
    {
      description: 'List MCP-managed workers and their persisted observable state.',
      inputSchema: {
        runId: z.string().optional(),
        activeOnly: z.boolean().optional(),
      },
      outputSchema: {
        workers: z.array(workerRecordSchema),
      },
    },
    async ({ runId, activeOnly }) => {
      logWorkflow('tool:list_workers', 'requested', { runId: runId ?? null, activeOnly: Boolean(activeOnly) })
      const structuredContent = {
        workers: activeWorkerRuntime.listWorkers({
          runId,
          activeOnly,
        }),
      }
      logWorkflow('tool:list_workers', 'completed', { count: structuredContent.workers.length })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'stop_worker',
    {
      description: 'Stop one MCP-managed worker by workerId or nickname and persist the stop reason.',
      inputSchema: {
        workerId: z.string().optional(),
        nickname: z.string().optional(),
        reason: z.string().min(1),
      },
      outputSchema: workerRecordSchema,
    },
    async ({ workerId, nickname, reason }) => {
      if (!workerId && !nickname) {
        throw new Error('stop_worker requires workerId or nickname')
      }

      logWorkflow('tool:stop_worker', 'requested', {
        workerId: workerId ?? null,
        nickname: nickname ?? null,
      })
      const structuredContent = workerId
        ? activeWorkerRuntime.stopWorker({ workerId, reason })
        : activeWorkerRuntime.stopWorker({ nickname: nickname as string, reason })
      activeBus.publishWorkerStopped({
        runId: structuredContent.runId,
        owner: 'workflow_mcp',
        role: structuredContent.role,
        nickname: structuredContent.nickname,
        reason,
      })
      logWorkflow('tool:stop_worker', 'completed', {
        workerId: structuredContent.workerId,
        nickname: structuredContent.nickname,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'publish_run_status',
    {
      description: 'Publish one shared run status event so the bus shows startup and phase transitions.',
      inputSchema: {
        runId: z.string().min(1),
        phase: z.string().min(1),
        owner: z.string().min(1),
        summary: z.string().min(1),
      },
      outputSchema: {
        runId: z.string(),
        phase: z.string(),
        owner: z.string(),
        summary: z.string(),
        at: z.string(),
      },
    },
    async ({ runId, phase, owner, summary }) => {
      logWorkflow('tool:publish_run_status', 'requested', { runId, phase, owner })
      const structuredContent = activeBus.publishRunStatus({
        runId,
        phase,
        owner,
        summary,
      })
      logWorkflow('tool:publish_run_status', 'completed', { runId, phase, owner })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'append_spawn_request',
    {
      description: 'Append one worker spawn request to the shared workflow bus.',
      inputSchema: {
        runId: z.string().min(1),
        askedBy: z.string().min(1),
        scope: z.string().min(1),
        text: z.string().min(1),
        context: z.string().optional(),
        requestedRole: z.string().min(1),
        priority: z.enum(['advisory', 'blocking']).optional(),
        tags: z.array(z.string()).optional(),
      },
      outputSchema: {
        requestId: z.string(),
        runId: z.string(),
        askedBy: z.string(),
        askedAt: z.string(),
        scope: z.string(),
        text: z.string(),
        context: z.string().nullable(),
        requestedRole: z.string(),
        priority: z.enum(['advisory', 'blocking']),
        status: z.enum(['open', 'fulfilled', 'dismissed']),
        fulfilledBy: z.string().nullable(),
        fulfilledAt: z.string().nullable(),
        fulfillmentNote: z.string().nullable(),
        tags: z.array(z.string()),
      },
    },
    async ({ runId, askedBy, scope, text, context: requestContext, requestedRole, priority, tags }) => {
      logWorkflow('tool:append_spawn_request', 'requested', {
        runId,
        askedBy,
        scope,
        requestedRole,
      })
      const structuredContent = activeBus.appendSpawnRequest({
        runId,
        askedBy,
        scope,
        text,
        context: requestContext,
        requestedRole,
        priority,
        tags,
      })
      logWorkflow('tool:append_spawn_request', 'completed', {
        requestId: structuredContent.requestId,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'append_user_question',
    {
      description: 'Append one user-facing question to the shared workflow bus when a planner or worker is blocked on a user decision.',
      inputSchema: {
        runId: z.string().min(1),
        askedBy: z.string().min(1),
        scope: z.string().min(1),
        text: z.string().min(1),
        context: z.string().optional(),
        priority: z.enum(['advisory', 'blocking']).optional(),
        tags: z.array(z.string()).optional(),
      },
      outputSchema: workflowUserQuestionSchema.shape,
    },
    async ({ runId, askedBy, scope, text, context, priority, tags }) => {
      logWorkflow('tool:append_user_question', 'requested', { runId, askedBy, scope, priority: priority ?? 'advisory' })
      const structuredContent = activeBus.appendUserQuestion({
        runId,
        askedBy,
        scope,
        text,
        context,
        priority,
        tags,
      })
      logWorkflow('tool:append_user_question', 'completed', { runId, questionId: structuredContent.questionId })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'list_open_spawn_requests',
    {
      description: 'List all currently open worker spawn requests from the shared bus.',
      inputSchema: {},
      outputSchema: {
        requests: z.array(
          z.object({
            requestId: z.string(),
            runId: z.string(),
            askedBy: z.string(),
            askedAt: z.string(),
            scope: z.string(),
            text: z.string(),
            context: z.string().nullable(),
            requestedRole: z.string(),
            priority: z.enum(['advisory', 'blocking']),
            status: z.enum(['open', 'fulfilled', 'dismissed']),
            fulfilledBy: z.string().nullable(),
            fulfilledAt: z.string().nullable(),
            fulfillmentNote: z.string().nullable(),
            tags: z.array(z.string()),
          })
        ),
      },
    },
    async () => {
      logWorkflow('tool:list_open_spawn_requests', 'requested')
      const structuredContent = { requests: activeBus.listOpenSpawnRequests() }
      logWorkflow('tool:list_open_spawn_requests', 'completed', {
        count: structuredContent.requests.length,
      })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'list_open_user_questions',
    {
      description: 'List open user-facing workflow questions from the shared bus.',
      inputSchema: {},
      outputSchema: {
        questions: z.array(workflowUserQuestionSchema),
      },
    },
    async () => {
      logWorkflow('tool:list_open_user_questions', 'requested')
      const structuredContent = {
        questions: activeBus.listOpenUserQuestions(),
      }
      logWorkflow('tool:list_open_user_questions', 'completed', { count: structuredContent.questions.length })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'queue_long_phone_demo_planner_job',
    {
      description: 'Queue an explicit planner job to create the long phone demo video without auto-restarting an idle run.',
      inputSchema: {
        runId: z.string().min(1),
        frontendUrl: z.string().url(),
        task: z.string().optional(),
      },
      outputSchema: {
        requestId: z.string(),
        runId: z.string(),
        askedBy: z.string(),
        askedAt: z.string(),
        scope: z.string(),
        text: z.string(),
        context: z.string().nullable(),
        requestedRole: z.string(),
        priority: z.enum(['advisory', 'blocking']),
        status: z.enum(['open', 'fulfilled', 'dismissed']),
        fulfilledBy: z.string().nullable(),
        fulfilledAt: z.string().nullable(),
        fulfillmentNote: z.string().nullable(),
        fulfilledWorkerId: z.string().nullable(),
        tags: z.array(z.string()),
        dependsOn: z.array(z.string()),
      },
    },
    async ({ runId, frontendUrl, task }) => {
      logWorkflow('tool:queue_long_phone_demo_planner_job', 'requested', { runId, frontendUrl })
      const structuredContent = queueLongPhoneDemoPlannerJob(activeBus, {
        runId,
        frontendUrl,
        task,
      })
      logWorkflow('tool:queue_long_phone_demo_planner_job', 'completed', {
        runId,
        requestId: structuredContent.requestId,
      })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'fulfill_spawn_request',
    {
      description: 'Mark one worker spawn request fulfilled after a worker has actually been spawned.',
      inputSchema: {
        requestId: z.string().min(1),
        fulfilledBy: z.string().min(1),
        fulfillmentNote: z.string().min(1),
      },
      outputSchema: {
        requestId: z.string(),
        runId: z.string(),
        askedBy: z.string(),
        askedAt: z.string(),
        scope: z.string(),
        text: z.string(),
        context: z.string().nullable(),
        requestedRole: z.string(),
        priority: z.enum(['advisory', 'blocking']),
        status: z.enum(['open', 'fulfilled', 'dismissed']),
        fulfilledBy: z.string().nullable(),
        fulfilledAt: z.string().nullable(),
        fulfillmentNote: z.string().nullable(),
        tags: z.array(z.string()),
      },
    },
    async ({ requestId, fulfilledBy, fulfillmentNote }) => {
      logWorkflow('tool:fulfill_spawn_request', 'requested', { requestId, fulfilledBy })
      const structuredContent = activeBus.fulfillSpawnRequest({ requestId, fulfilledBy, fulfillmentNote })
      logWorkflow('tool:fulfill_spawn_request', 'completed', { requestId })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'list_recent_events',
    {
      description: 'List recent workflow bus events for status feeds and live dashboards.',
      inputSchema: {
        limit: z.number().int().positive().max(200).optional(),
      },
      outputSchema: {
        events: z.array(
          z.object({
            eventId: z.string(),
            at: z.string(),
            type: z.string(),
            payload: z.record(z.string(), z.unknown()),
          })
        ),
      },
    },
    async ({ limit }) => {
      logWorkflow('tool:list_recent_events', 'requested', { limit: limit ?? 20 })
      const structuredContent = { events: activeBus.listRecentEvents(limit) }
      logWorkflow('tool:list_recent_events', 'completed', {
        count: structuredContent.events.length,
      })
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'plan_workflow_iteration',
    {
      description: 'Generate the next workflow plan using the repo agent roles and artifact contract.',
      inputSchema: {
        task: z.string().min(1),
        scenario: z.enum(['admin', 'phone', 'both']),
        frontendUrl: z.string().url(),
        verifierFinding: z.string().optional(),
        stallFinding: z.string().optional(),
      },
      outputSchema: {
        summary: z.string(),
        steps: z.array(
          z.object({
            owner: z.string(),
            artifact: z.string(),
            successCheck: z.string(),
          })
        ),
      },
    },
    async ({ task, scenario, frontendUrl, verifierFinding, stallFinding }) => {
      logWorkflow('tool:plan_workflow_iteration', 'requested', {
        scenario,
        frontendUrl,
        hasVerifierFinding: Boolean(verifierFinding?.trim()),
        hasStallFinding: Boolean(stallFinding?.trim()),
      })
      const structuredContent = planWorkflowIteration({
        task,
        scenario,
        frontendUrl,
        verifierFinding,
        stallFinding,
      })
      logWorkflow('tool:plan_workflow_iteration', 'completed', { steps: structuredContent.steps.length })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'publish_planner_jobs',
    {
      description: 'Run the planner and publish its worker jobs to the shared bus as spawn requests.',
      inputSchema: {
        runId: z.string().min(1),
        task: z.string().min(1),
        scenario: z.enum(['admin', 'phone', 'both']),
        frontendUrl: z.string().url(),
        verifierFinding: z.string().optional(),
        stallFinding: z.string().optional(),
      },
      outputSchema: {
        summary: z.string(),
        jobs: z.array(
          z.object({
            requestId: z.string(),
            step: z.object({
              owner: z.string(),
              artifact: z.string(),
              successCheck: z.string(),
            }),
          })
        ),
      },
    },
    async ({ runId, task, scenario, frontendUrl, verifierFinding, stallFinding }) => {
      logWorkflow('tool:publish_planner_jobs', 'requested', { runId, scenario, frontendUrl })
      const plan = planWorkflowIteration({
        task,
        scenario,
        frontendUrl,
        verifierFinding,
        stallFinding,
      })
      const jobs = publishPlannerJobs(activeBus, {
        runId,
        summary: plan.summary,
        plan,
      })
      logWorkflow('tool:publish_planner_jobs', 'completed', { runId, jobs: jobs.length })

      const structuredContent = { summary: plan.summary, jobs }
      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'run_orchestrator_turn',
    {
      description: 'Run one orchestrator decision tick: inspect workers, detect stalls, ask the planner for the next handoff, and publish worker jobs to the bus without spawning workers directly.',
      inputSchema: {
        runId: z.string().min(1),
        task: z.string().min(1),
        scenario: z.enum(['admin', 'phone', 'both']),
        frontendUrl: z.string().url(),
        staleAfterMs: z.number().int().positive().optional(),
      },
      outputSchema: {
        plan: z.object({
          summary: z.string(),
          steps: z.array(
            z.object({
              owner: z.string(),
              artifact: z.string(),
              successCheck: z.string(),
            })
          ),
        }),
        jobs: z.array(
          z.object({
            requestId: z.string(),
            step: z.object({
              owner: z.string(),
              artifact: z.string(),
              successCheck: z.string(),
            }),
          })
        ),
        stalledWorkers: z.array(
          z.object({
            worker: workerRecordSchema,
            idleForMs: z.number().int(),
            evidence: z.array(z.string()),
          })
        ),
        nextState: orchestratorDecisionStateSchema,
      },
    },
    async ({ runId, task, scenario, frontendUrl, staleAfterMs }) => {
      logWorkflow('tool:run_orchestrator_turn', 'requested', {
        runId,
        scenario,
        frontendUrl,
        staleAfterMs: staleAfterMs ?? null,
      })
      const structuredContent = runOrchestratorTurn({
        runId,
        task,
        scenario,
        frontendUrl,
        workerRuntime: activeWorkerRuntime,
        bus: activeBus,
        staleAfterMs,
        previousState: readOrchestratorState(activeContext, runId),
      })
      writeOrchestratorState(activeContext, structuredContent.nextState)
      appendOrchestratorTickHistory(activeContext, structuredContent.nextState)
      logWorkflow('tool:run_orchestrator_turn', 'completed', {
        runId,
        stalledWorkers: structuredContent.stalledWorkers.length,
        jobs: structuredContent.jobs.length,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'worker_turn',
    {
      description: 'Report one worker turn result and deterministically get the planner-decided next steps published to the bus.',
      inputSchema: {
        runId: z.string().min(1),
        role: workerRoleSchema,
        nickname: z.string().min(1),
        scope: z.string().min(1),
        result: z.string().min(1),
        task: z.string().min(1),
        scenario: z.enum(['admin', 'phone', 'both']),
        frontendUrl: z.string().url(),
      },
      outputSchema: {
        plan: z.object({
          summary: z.string(),
          steps: z.array(workflowStepSchema),
        }),
        jobs: z.array(
          z.object({
            requestId: z.string(),
            step: workflowStepSchema,
          })
        ),
        plannerWorker: workerRecordSchema.nullable(),
        nextState: orchestratorDecisionStateSchema,
      },
    },
    async ({ runId, role, nickname, scope, result, task, scenario, frontendUrl }) => {
      logWorkflow('tool:worker_turn', 'requested', { runId, role, nickname, scope })
      const previousState = readOrchestratorState(activeContext, runId)
      const structuredContent = runWorkerTurn({
        runId,
        role,
        nickname,
        scope,
        result,
        task,
        scenario,
        frontendUrl,
        bus: activeBus,
        workerRuntime: activeWorkerRuntime,
        previousState,
      })
      writeOrchestratorState(activeContext, structuredContent.nextState)
      logWorkflow('tool:worker_turn', 'completed', {
        runId,
        role,
        jobs: structuredContent.jobs.length,
        plannerWorker: structuredContent.plannerWorker?.nickname ?? null,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'planner_turn',
    {
      description:
        'Submit the planner\'s complete decided plan for a run and publish the resulting spawn requests to the bus. ' +
        'planner_turn spawns a worker immediately for every included step; a step only waits if its ' +
        'dependsOnArtifacts names another step\'s artifact, in which case the supervisor holds it until that ' +
        'dependency is fulfilled.',
      inputSchema: {
        runId: z.string().min(1),
        summary: z.string().min(1),
        steps: z.array(
          z.object({
            owner: workflowAgentSchema,
            artifact: z.string().min(1),
            successCheck: z.string().min(1),
            dependsOnArtifacts: z.array(z.string()).optional(),
          })
        ),
      },
      outputSchema: {
        jobs: z.array(
          z.object({
            requestId: z.string(),
            step: z.object({
              owner: z.string(),
              artifact: z.string(),
              successCheck: z.string(),
              dependsOnArtifacts: z.array(z.string()).optional(),
            }),
          })
        ),
      },
    },
    async ({ runId, summary, steps }) => {
      logWorkflow('tool:planner_turn', 'requested', { runId, steps: steps.length })
      const structuredContent = runPlannerTurn({
        runId,
        summary,
        steps,
        bus: activeBus,
      })
      logWorkflow('tool:planner_turn', 'completed', { runId, jobs: structuredContent.jobs.length })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'read_orchestrator_state',
    {
      description: 'Read the persisted orchestrator decision state for a run, or return the default empty state if none has been written yet.',
      inputSchema: {
        runId: z.string().min(1),
      },
      outputSchema: orchestratorDecisionStateSchema.shape,
    },
    async ({ runId }) => {
      logWorkflow('tool:read_orchestrator_state', 'requested', { runId })
      const structuredContent = readOrchestratorState(activeContext, runId)
      logWorkflow('tool:read_orchestrator_state', 'completed', {
        runId,
        tickCount: structuredContent.tickCount,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'read_orchestrator_tick_history',
    {
      description: 'Read the recorded orchestrator tick history for a run (most recent ticks), for building a timeline view.',
      inputSchema: {
        runId: z.string().min(1),
      },
      outputSchema: {
        runId: z.string(),
        entries: z.array(orchestratorDecisionStateSchema),
      },
    },
    async ({ runId }) => {
      logWorkflow('tool:read_orchestrator_tick_history', 'requested', { runId })
      const structuredContent = readOrchestratorTickHistory(activeContext, runId)
      logWorkflow('tool:read_orchestrator_tick_history', 'completed', {
        runId,
        entries: structuredContent.entries.length,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'write_orchestrator_state',
    {
      description: 'Persist the orchestrator decision state for a run so the next orchestrator tick can continue from the prior decision context.',
      inputSchema: orchestratorDecisionStateSchema.shape,
      outputSchema: {
        statePath: z.string(),
        state: orchestratorDecisionStateSchema,
      },
    },
    async (input) => {
      const state = input as OrchestratorDecisionState
      logWorkflow('tool:write_orchestrator_state', 'requested', {
        runId: state.runId,
        tickCount: state.tickCount,
      })
      const statePath = writeOrchestratorState(activeContext, state)
      const structuredContent = { statePath, state }
      logWorkflow('tool:write_orchestrator_state', 'completed', {
        runId: state.runId,
        statePath,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'collect_workflow_state',
    {
      description:
        "Inspect the managed workflow artifact directory and summarize which of this run's planner-declared artifacts exist.",
      inputSchema: {
        runId: z.string().min(1),
      },
      outputSchema: {
        outputDir: z.string(),
        artifacts: z.array(
          z.object({
            name: z.string(),
            path: z.string(),
            exists: z.boolean(),
            sizeBytes: z.number().nullable(),
            updatedAt: z.string().nullable(),
            preview: z.string().nullable(),
          })
        ),
      },
    },
    async ({ runId }) => {
      logWorkflow('tool:collect_workflow_state', 'requested', { runId })
      const artifactNames = listPlannerDeclaredArtifacts(activeBus, runId)
      const structuredContent = collectWorkflowState(activeContext, runId, artifactNames)
      logWorkflow('tool:collect_workflow_state', 'completed', {
        runId,
        artifacts: structuredContent.artifacts.filter((artifact) => artifact.exists).length,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'read_workflow_artifact',
    {
      description:
        'Read one managed workflow artifact from front/demo-output/agents-sdk, scoped to the given run so concurrent runs never read each other\'s files.',
      inputSchema: {
        runId: z.string().min(1),
        artifactName: z.string(),
      },
      outputSchema: {
        artifactName: z.string(),
        content: z.string(),
      },
    },
    async ({ runId, artifactName }) => {
      logWorkflow('tool:read_workflow_artifact', 'requested', { runId, artifactName })
      const content = readWorkflowArtifact(activeContext, runId, artifactName)
      const structuredContent = { artifactName, content }
      logWorkflow('tool:read_workflow_artifact', 'completed', {
        artifactName,
        bytes: content.length,
      })

      return {
        content: [{ type: 'text', text: content }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'write_workflow_artifact',
    {
      description:
        'Write one managed workflow artifact into front/demo-output/agents-sdk, scoped to the given run so concurrent runs and workers never overwrite each other\'s files.',
      inputSchema: {
        runId: z.string().min(1),
        artifactName: z.string(),
        content: z.string(),
      },
      outputSchema: {
        artifactName: z.string(),
        path: z.string(),
      },
    },
    async ({ runId, artifactName, content }) => {
      logWorkflow('tool:write_workflow_artifact', 'requested', {
        runId,
        artifactName,
        bytes: content.length,
      })
      const artifactPath = writeWorkflowArtifact(activeContext, runId, artifactName, content)
      const structuredContent = { artifactName, path: artifactPath }
      logWorkflow('tool:write_workflow_artifact', 'completed', {
        artifactName,
        path: artifactPath,
      })

      return {
        content: [{ type: 'text', text: artifactPath }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'build_guarded_command',
    {
      description: 'Build one of the approved repo environment commands without executing it.',
      inputSchema: {
        operation: z.enum(['record_demo', 'frontend_typecheck', 'frontend_test']),
        scenario: z.enum(['admin', 'phone', 'both']).optional(),
        executionMode: z.enum(['local', 'docker']).optional(),
        frontendUrl: z.string().url().optional(),
        testTarget: z.string().optional(),
      },
      outputSchema: {
        command: z.string(),
        args: z.array(z.string()),
        cwd: z.string(),
      },
    },
    async ({ operation, scenario, executionMode, frontendUrl, testTarget }) => {
      logWorkflow('tool:build_guarded_command', 'requested', {
        operation,
        scenario,
        executionMode,
        frontendUrl,
        testTarget,
      })
      const structuredContent = buildGuardedCommand({
        operation,
        rootDir: ROOT_DIR,
        frontDir: FRONT_DIR,
        scenario,
        executionMode,
        frontendUrl,
        testTarget,
      })
      logWorkflow('tool:build_guarded_command', 'completed', {
        operation,
        command: structuredContent.command,
      })

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  server.registerTool(
    'run_guarded_command',
    {
      description: 'Execute one approved repo environment command and return structured stdout/stderr results.',
      inputSchema: {
        operation: z.enum(['record_demo', 'frontend_typecheck', 'frontend_test']),
        scenario: z.enum(['admin', 'phone', 'both']).optional(),
        executionMode: z.enum(['local', 'docker']).optional(),
        frontendUrl: z.string().url().optional(),
        testTarget: z.string().optional(),
      },
      outputSchema: {
        command: z.string(),
        args: z.array(z.string()),
        cwd: z.string(),
        exitCode: z.number(),
        stdout: z.string(),
        stderr: z.string(),
        success: z.boolean(),
      },
    },
    async ({ operation, scenario, executionMode, frontendUrl, testTarget }) => {
      logWorkflow('tool:run_guarded_command', 'requested', {
        operation,
        scenario,
        executionMode,
        frontendUrl,
        testTarget,
      })
      const spec = buildGuardedCommand({
        operation,
        rootDir: ROOT_DIR,
        frontDir: FRONT_DIR,
        scenario,
        executionMode,
        frontendUrl,
        testTarget,
      })

      const result = activeCommandRunner(spec)
      logWorkflow('tool:run_guarded_command', 'completed', {
        operation,
        exitCode: result.status ?? 1,
        success: result.status === 0,
      })

      const structuredContent = {
        command: spec.command,
        args: spec.args,
        cwd: spec.cwd,
        exitCode: result.status ?? 1,
        stdout: result.stdout ?? '',
        stderr: result.stderr ?? '',
        success: result.status === 0,
      }

      return {
        content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
        structuredContent,
      }
    }
  )

  return server
}
