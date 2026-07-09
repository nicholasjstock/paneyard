import * as fs from 'fs'

import {
  buildPendingSpawnKeys,
  buildStalledWorkerRecoveryPlan,
  publishPlannerJobs,
  type DemoScenario,
  type FileSystemAdapter,
  type OrchestratorDecisionState,
  type PlanWorkflowIterationResult,
  type PlannerBusJob,
  type WorkflowStep,
} from './workflow-mcp'
import type { WorkflowWorkerRecord } from './workflow-worker-runtime'

export type OrchestratorWorkerRuntime = {
  listWorkers: (args?: { runId?: string; activeOnly?: boolean }) => Promise<WorkflowWorkerRecord[]>
  spawnWorker: (args: {
    runId: string
    role: WorkflowWorkerRecord['role']
    nickname: string
    reason: string
    scope: string
    prompt: string
  }) => Promise<WorkflowWorkerRecord>
}

type OrchestratorBus = Parameters<typeof publishPlannerJobs>[0] & {
  listOpenSpawnRequests: () => Promise<Array<{ runId: string }>>
  listOpenUserQuestions: () => Promise<Array<{ runId: string; priority: 'advisory' | 'blocking' }>>
  publishRunStatus: (args: {
    runId: string
    phase: string
    owner: string
    summary: string
  }) => Promise<unknown>
  publishWorkerSpawned: (args: {
    runId: string
    owner: string
    role: string
    nickname: string
    reason: string
  }) => Promise<unknown>
}

export type OrchestratorTurnFinding = {
  worker: WorkflowWorkerRecord
  idleForMs: number
  evidence: string[]
}

export type OrchestratorTurnArgs = {
  runId: string
  task: string
  scenario: DemoScenario
  frontendUrl: string
  workerRuntime: OrchestratorWorkerRuntime
  bus: OrchestratorBus
  fileSystem?: Pick<FileSystemAdapter, 'existsSync' | 'readFileSync' | 'statSync'>
  now?: Date
  staleAfterMs?: number
  previousState?: OrchestratorDecisionState
}

export type OrchestratorTurnResult = {
  // null when not stalled — a non-stalled tick is a pure no-op and builds no
  // plan at all, rather than publishing an inert "waiting" bookkeeping step.
  plan: PlanWorkflowIterationResult | null
  jobs: PlannerBusJob[]
  stalledWorkers: OrchestratorTurnFinding[]
  nextState: OrchestratorDecisionState
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '')
}

export function buildWorkerNickname(role: WorkflowWorkerRecord['role']): string {
  switch (role) {
    case 'worker':
      return 'worker'
    case 'planner':
      return 'planner'
    case 'orchestrator':
      return 'orchestrator'
  }
}

export function buildRequestedWorkerPrompt(args: {
  runId: string
  request: {
    askedBy: string
    scope: string
    text: string
    context: string | null
    requestedRole: string | null
  }
}): string {
  return [
    `Run ${args.runId}.`,
    `Bus request: ${args.request.scope}.`,
    `Requested by: ${args.request.askedBy}.`,
    args.request.requestedRole ? `Target role: ${args.request.requestedRole}.` : null,
    args.request.text,
    args.request.context ? `Context: ${args.request.context}.` : null,
    `Write your report via write_workflow_artifact using artifactName="${args.request.scope}". Use the shared workflow bus for blockers.`,
  ]
    .filter((part): part is string => typeof part === 'string' && part.length > 0)
    .join(' ')
}

function readMtime(fileSystem: Pick<FileSystemAdapter, 'existsSync' | 'statSync'>, filePath: string): number | null {
  if (!fileSystem.existsSync(filePath)) {
    return null
  }

  try {
    return fileSystem.statSync(filePath).mtime.getTime()
  } catch {
    return null
  }
}

function collectLatestProgressAt(
  fileSystem: Pick<FileSystemAdapter, 'existsSync' | 'statSync'>,
  worker: WorkflowWorkerRecord
): { timestamp: number | null; evidence: string[] } {
  const evidence: string[] = []
  const timestamps = [
    ['log', readMtime(fileSystem, worker.logPath)] as const,
    ['last-message', readMtime(fileSystem, worker.lastMessagePath)] as const,
    ['prompt', readMtime(fileSystem, worker.promptPath)] as const,
  ]

  let latest = Number.NEGATIVE_INFINITY
  for (const [label, timestamp] of timestamps) {
    if (timestamp == null) {
      continue
    }

    evidence.push(`${label} mtime=${new Date(timestamp).toISOString()}`)
    latest = Math.max(latest, timestamp)
  }

  if (!Number.isFinite(latest) || latest === Number.NEGATIVE_INFINITY) {
    return { timestamp: null, evidence }
  }

  return { timestamp: latest, evidence }
}

export function detectStalledWorkers(args: {
  workers: WorkflowWorkerRecord[]
  fileSystem?: Pick<FileSystemAdapter, 'existsSync' | 'statSync'>
  now?: Date
  staleAfterMs?: number
}): OrchestratorTurnFinding[] {
  const fileSystem = args.fileSystem ?? fs
  const nowMs = (args.now ?? new Date()).getTime()
  const staleAfterMs = args.staleAfterMs ?? 120_000

  return args.workers.flatMap((worker) => {
    if (worker.status !== 'running') {
      return []
    }

    const latestProgress = collectLatestProgressAt(fileSystem, worker)
    if (latestProgress.timestamp == null) {
      return []
    }

    const idleForMs = nowMs - latestProgress.timestamp
    if (idleForMs < staleAfterMs) {
      return []
    }

    return [
      {
        worker,
        idleForMs,
        evidence: [
          `worker=${worker.nickname}`,
          `role=${worker.role}`,
          `idleForMs=${idleForMs}`,
          ...latestProgress.evidence,
        ],
      },
    ]
  })
}

export function buildStallFinding(stalls: OrchestratorTurnFinding[]): string {
  return stalls
    .map((stall) => {
      const worker = stall.worker
      return [
        `Stalled worker ${worker.nickname} (${worker.role})`,
        `runId=${worker.runId}`,
        `idleForMs=${stall.idleForMs}`,
        `scope=${worker.scope}`,
        `reason=${worker.reason}`,
        `evidence=${stall.evidence.join('; ')}`,
      ].join(' | ')
    })
    .join('\n')
}

// A run can go dead without ever looking "stalled": a worker stops (crash,
// or a clean exit whose worker_turn call never landed) without producing a
// follow-up spawn request. detectStalledWorkers can't see this — it only
// looks at workers still status==='running'. Once a run has made real
// progress (phase advanced past 'starting') but ends up with nothing
// active and nothing pending, and was never told it's done ('completed'),
// that's the same class of problem as a stalled worker: ask a planner to
// look at what happened and decide the next bounded handoff.
export function buildDeadEndFinding(args: { runId: string; followingSteps: WorkflowStep[] }): string {
  return [
    `Run ${args.runId} has no active workers and no open spawn requests, but was not marked completed.`,
    `followingSteps queue at last check: ${JSON.stringify(args.followingSteps)}`,
    'The most recent worker likely stopped without completing its worker_turn handoff (crashed, or the call failed) — inspect its last known report/artifact and decide whether to retry, fix, or escalate to the user.',
  ].join(' ')
}

export async function runOrchestratorTurn(args: OrchestratorTurnArgs): Promise<OrchestratorTurnResult> {
  const fileSystem = args.fileSystem ?? fs
  const previousState = args.previousState
  await args.bus.publishRunStatus({
    runId: args.runId,
    phase: 'starting',
    owner: 'orchestrator',
    summary: `Opening orchestrator phase for ${args.scenario} scenario on ${trimTrailingSlash(args.frontendUrl)}; coordinating the next recorder and verifier handoff.`,
  })
  const workers = await args.workerRuntime.listWorkers({ runId: args.runId, activeOnly: true })
  const stalledWorkers = detectStalledWorkers({
    workers,
    fileSystem,
    now: args.now,
    staleAfterMs: args.staleAfterMs,
  })
  const stallFinding = stalledWorkers.length > 0 ? buildStallFinding(stalledWorkers) : undefined

  // A run that made real progress (phase advanced past 'starting') but now
  // has nothing active and nothing pending, and was never marked
  // 'completed', has gone dead — the same class of problem as a stalled
  // worker, just invisible to detectStalledWorkers because there's no
  // running worker left to look at.
  const allOpenSpawnRequests = await args.bus.listOpenSpawnRequests()
  const openSpawnRequests = allOpenSpawnRequests.filter((request) => request.runId === args.runId)
  const isDeadEnd =
    !stallFinding &&
    workers.length === 0 &&
    openSpawnRequests.length === 0 &&
    previousState !== undefined &&
    previousState.phase !== 'starting' &&
    previousState.phase !== 'completed'
  const deadEndFinding = isDeadEnd
    ? buildDeadEndFinding({ runId: args.runId, followingSteps: previousState?.followingSteps ?? [] })
    : undefined
  const recoveryFinding = stallFinding ?? deadEndFinding

  // A recovery planner may have already escalated this exact stall/dead-end
  // to a blocking user question (e.g. after a retry also failed). Without
  // this check, the orchestrator has no memory of that — it just re-detects
  // the same still-idle workers next tick and spawns *another* recovery
  // planner to redundantly re-investigate something already awaiting a
  // human answer, ignoring whatever policy that first planner decided on.
  const openUserQuestions = await args.bus.listOpenUserQuestions()
  const hasOpenBlockingQuestion = openUserQuestions.some(
    (question) => question.runId === args.runId && question.priority === 'blocking'
  )

  // A non-stalled, non-dead-end tick is a pure no-op: worker_turn/planner_turn
  // own all real progress, so there is nothing for the orchestrator to
  // decide or publish here. Only a detected stall or dead end gives the
  // orchestrator a reason to act — and only while nothing about it is
  // already sitting in front of the user.
  const plan =
    recoveryFinding && recoveryFinding.trim().length > 0 && !hasOpenBlockingQuestion
      ? buildStalledWorkerRecoveryPlan({
          task: args.task,
          scenario: args.scenario,
          frontendUrl: trimTrailingSlash(args.frontendUrl),
          recoveryFinding,
          followingSteps: previousState?.followingSteps ?? [],
        })
      : null
  const jobs = plan
    ? await publishPlannerJobs(args.bus, {
        runId: args.runId,
        summary: plan.summary,
        plan,
        activeWorkerIds: new Set(workers.map((worker) => worker.workerId)),
      })
    : []
  const lastStallFinding = recoveryFinding ?? null
  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    phase: hasOpenBlockingQuestion
      ? 'blocked_on_user'
      : recoveryFinding
        ? 'stalled'
        : workers.length > 0
          ? 'waiting_on_workers'
          : previousState?.phase ?? 'starting',
    tickCount: (previousState?.tickCount ?? 0) + 1,
    lastPlanSummary: plan?.summary ?? previousState?.lastPlanSummary ?? null,
    pendingSpawnKeys: [...new Set([...(previousState?.pendingSpawnKeys ?? []), ...buildPendingSpawnKeys(args.runId, jobs)])],
    followingSteps: plan?.followingSteps ?? previousState?.followingSteps ?? [],
    lastStallFinding,
    lastUpdatedAt: (args.now ?? new Date()).toISOString(),
  }

  return {
    plan,
    jobs,
    stalledWorkers,
    nextState,
  }
}
