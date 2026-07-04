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
} from './workflow-mcp'
import type { WorkflowWorkerRecord } from './workflow-worker-runtime'

export type OrchestratorWorkerRuntime = {
  listWorkers: (args?: { runId?: string; activeOnly?: boolean }) => WorkflowWorkerRecord[]
  spawnWorker: (args: {
    runId: string
    role: WorkflowWorkerRecord['role']
    nickname: string
    reason: string
    scope: string
    prompt: string
  }) => WorkflowWorkerRecord
}

type OrchestratorBus = Parameters<typeof publishPlannerJobs>[0] & {
  publishRunStatus: (args: {
    runId: string
    phase: string
    owner: string
    summary: string
  }) => unknown
  publishWorkerSpawned: (args: {
    runId: string
    owner: string
    role: string
    nickname: string
    reason: string
  }) => unknown
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

export function runOrchestratorTurn(args: OrchestratorTurnArgs): OrchestratorTurnResult {
  const fileSystem = args.fileSystem ?? fs
  const previousState = args.previousState
  args.bus.publishRunStatus({
    runId: args.runId,
    phase: 'starting',
    owner: 'orchestrator',
    summary: `Opening orchestrator phase for ${args.scenario} scenario on ${trimTrailingSlash(args.frontendUrl)}; coordinating the next recorder and verifier handoff.`,
  })
  const workers = args.workerRuntime.listWorkers({ runId: args.runId, activeOnly: true })
  const stalledWorkers = detectStalledWorkers({
    workers,
    fileSystem,
    now: args.now,
    staleAfterMs: args.staleAfterMs,
  })
  const stallFinding = stalledWorkers.length > 0 ? buildStallFinding(stalledWorkers) : undefined

  // A non-stalled tick is a pure no-op: worker_turn/planner_turn own all real
  // progress, so there is nothing for the orchestrator to decide or publish
  // here. Only a detected stall gives the orchestrator a reason to act.
  const plan =
    stallFinding && stallFinding.trim().length > 0
      ? buildStalledWorkerRecoveryPlan({
          task: args.task,
          scenario: args.scenario,
          frontendUrl: trimTrailingSlash(args.frontendUrl),
          stallFinding,
          followingSteps: previousState?.followingSteps ?? [],
        })
      : null
  const jobs = plan
    ? publishPlannerJobs(args.bus, {
        runId: args.runId,
        summary: plan.summary,
        plan,
      })
    : []
  const lastStallFinding = stallFinding ?? null
  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    phase: stallFinding ? 'stalled' : workers.length > 0 ? 'waiting_on_workers' : previousState?.phase ?? 'starting',
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
