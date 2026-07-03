import * as fs from 'fs'

import {
  planWorkflowIteration,
  publishPlannerJobs,
  type DemoScenario,
  type FileSystemAdapter,
  type OrchestratorDecisionState,
  type PlanWorkflowIterationArgs,
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
  listOpenSpawnRequests: () => Array<{
    runId: string
    askedBy: string
    scope: string
    text: string
    context: string | null
    requestedRole: string
    priority: 'advisory' | 'blocking'
    status: 'open' | 'fulfilled' | 'dismissed'
    tags: string[]
  }>
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
  planner?: (args: PlanWorkflowIterationArgs) => PlanWorkflowIterationResult
}

export type OrchestratorTurnResult = {
  plan: PlanWorkflowIterationResult
  jobs: PlannerBusJob[]
  stalledWorkers: OrchestratorTurnFinding[]
  nextState: OrchestratorDecisionState
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '')
}

export function buildWorkerNickname(role: WorkflowWorkerRecord['role']): string {
  switch (role) {
    case 'demo_recorder':
      return 'demo-recorder'
    case 'demo_verifier':
      return 'demo-verifier'
    case 'front_fixer':
      return 'front-fixer'
    case 'back_fixer':
      return 'back-fixer'
    case 'infra_fixer':
      return 'infra-fixer'
    case 'general_fixer':
      return 'general-fixer'
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
    'Use the shared workflow bus for blockers and report progress through your standard artifact.',
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

function buildPendingSpawnKeys(runId: string, jobs: PlannerBusJob[]): string[] {
  return jobs.map((job) => JSON.stringify([runId, job.step.owner, job.step.artifact]))
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
  const planner = args.planner ?? planWorkflowIteration
  const plan = planner({
    task: args.task,
    scenario: args.scenario,
    frontendUrl: trimTrailingSlash(args.frontendUrl),
    stallFinding: stalledWorkers.length > 0 ? buildStallFinding(stalledWorkers) : undefined,
  })
  const jobs = publishPlannerJobs(args.bus, {
    runId: args.runId,
    summary: plan.summary,
    plan,
  })
  const lastStallFinding = stalledWorkers.length > 0 ? buildStallFinding(stalledWorkers) : null
  const nextState: OrchestratorDecisionState = {
    runId: args.runId,
    phase: 'planning',
    tickCount: (previousState?.tickCount ?? 0) + 1,
    lastPlanSummary: plan.summary,
    pendingSpawnKeys: [...new Set([...(previousState?.pendingSpawnKeys ?? []), ...buildPendingSpawnKeys(args.runId, jobs)])],
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
