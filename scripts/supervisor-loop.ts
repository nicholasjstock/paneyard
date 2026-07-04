import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

import { buildRequestedWorkerPrompt, buildWorkerNickname, runOrchestratorTurn } from './orchestrator-turn'
import {
  appendOrchestratorTickHistory,
  buildWorkflowContext,
  readOrchestratorState,
  writeOrchestratorState,
} from './workflow-mcp'
import { createWorkflowBus } from './workflow-bus'
import { createNodeWorkerProcessAdapter } from './workflow-worker-runtime-node'
import { createWorkflowWorkerRuntime, type WorkerDriver, type WorkflowWorkerRecord } from './workflow-worker-runtime'

type SupervisorLoopOptions = {
  runId?: string
  task?: string
  scenario?: 'admin' | 'phone' | 'both'
  frontendUrl?: string
  intervalMs: number
  staleAfterMs?: number
  once: boolean
}

type SpawnRequest = {
  requestId: string
  runId: string
  askedBy: string
  scope: string
  text: string
  context: string | null
  requestedRole: string
  status: 'open' | 'fulfilled' | 'dismissed'
  fulfilledWorkerId: string | null
  dependsOn: string[]
}

type WorkerRuntimeLike = Pick<ReturnType<typeof createWorkflowWorkerRuntime>, 'listWorkers' | 'spawnWorker'>
type WorkflowBusLike = Pick<
  ReturnType<typeof createWorkflowBus>,
  | 'listOpenSpawnRequests'
  | 'listSpawnRequests'
  | 'publishWorkerSpawned'
  | 'fulfillSpawnRequest'
>

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// PKG_ROOT: this package's own install location.
const PKG_ROOT = path.resolve(__dirname, '..')
// ROOT_DIR: the project being orchestrated (e.g. simple-retail-planner). See
// workflow-mcp-app.ts for the same pattern/rationale.
const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT ? path.resolve(process.env.WORKFLOW_TARGET_ROOT) : PKG_ROOT
const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
const OUTPUT_DIR = process.env.WORKFLOW_STATE_DIR
  ? path.resolve(process.env.WORKFLOW_STATE_DIR)
  : path.resolve(FRONT_DIR, 'demo-output', 'agents-sdk')
const BUS_PATH = path.join(OUTPUT_DIR, 'workflow-bus.json')
const ORCHESTRATOR_STATE_DIR = path.join(OUTPUT_DIR, 'orchestrator-state')
const WORKER_DRIVER: WorkerDriver = process.env.WORKFLOW_WORKER_DRIVER === 'claude' ? 'claude' : 'codex'

type LatestPersistedRun = {
  runId: string
  summary: string | null
}

function parseArgs(argv: string[]): SupervisorLoopOptions {
  const options: SupervisorLoopOptions = {
    intervalMs: 5_000,
    once: false,
  }

  for (const arg of argv) {
    if (arg === '--once') {
      options.once = true
      continue
    }

    const [flag, value] = arg.split('=', 2)
    switch (flag) {
      case '--run-id':
        options.runId = value
        break
      case '--task':
        options.task = value
        break
      case '--scenario':
        if (value === 'admin' || value === 'phone' || value === 'both') {
          options.scenario = value
        }
        break
      case '--frontend-url':
        options.frontendUrl = value
        break
      case '--interval-ms':
        if (value && Number.isFinite(Number(value)) && Number(value) > 0) {
          options.intervalMs = Number(value)
        }
        break
      case '--stale-after-ms':
        if (value && Number.isFinite(Number(value)) && Number(value) > 0) {
          options.staleAfterMs = Number(value)
        }
        break
      default:
        break
    }
  }

  return options
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

function usage(): string {
  return [
    'Usage: supervisor-loop.ts [options]',
    '',
    'Options:',
    '  --run-id=<id>',
    '  --task=<text>',
    '  --scenario=<admin|phone|both>',
    '  --frontend-url=<url>',
    '  --interval-ms=<n>',
    '  --stale-after-ms=<n>',
    '  --once',
  ].join('\n')
}

export function resolveLatestPersistedRun(
  stateDir: string,
  fileSystem: Pick<typeof fs, 'existsSync' | 'readdirSync' | 'readFileSync' | 'statSync'> = fs
): LatestPersistedRun | null {
  if (!fileSystem.existsSync(stateDir)) {
    return null
  }

  const entries = fileSystem
    .readdirSync(stateDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json') && !entry.name.endsWith('.history.json'))

  let latest: { runId: string; summary: string | null; updatedAt: number; sortKey: string } | null = null

  for (const entry of entries) {
    const filePath = path.join(stateDir, entry.name)

    try {
      const parsed = JSON.parse(fileSystem.readFileSync(filePath, 'utf8')) as Partial<{
        runId: string
        lastPlanSummary: string | null
        lastUpdatedAt: string | null
      }>
      const runId = typeof parsed.runId === 'string' && parsed.runId.length > 0 ? parsed.runId : entry.name.replace(/\.json$/, '')
      const parsedUpdatedAt =
        typeof parsed.lastUpdatedAt === 'string' && Number.isFinite(Date.parse(parsed.lastUpdatedAt))
          ? Date.parse(parsed.lastUpdatedAt)
          : Number.NaN
      const statUpdatedAt = fileSystem.statSync(filePath).mtime.getTime()
      const updatedAt = Number.isFinite(parsedUpdatedAt) ? parsedUpdatedAt : statUpdatedAt
      const candidate = {
        runId,
        summary: typeof parsed.lastPlanSummary === 'string' ? parsed.lastPlanSummary : null,
        updatedAt,
        sortKey: entry.name,
      }

      if (
        latest === null ||
        candidate.updatedAt > latest.updatedAt ||
        (candidate.updatedAt === latest.updatedAt && candidate.sortKey.localeCompare(latest.sortKey) > 0)
      ) {
        latest = candidate
      }
    } catch {
      continue
    }
  }

  return latest ? { runId: latest.runId, summary: latest.summary } : null
}

function buildSpawnRequestKey(request: SpawnRequest): string | null {
  if (!request.requestedRole) {
    return null
  }

  return JSON.stringify([request.runId, request.requestedRole, request.scope])
}

function buildActiveWorkerKey(worker: WorkflowWorkerRecord): string {
  return JSON.stringify([worker.runId, worker.role, worker.scope])
}

function buildUniqueNickname(baseNickname: string, workers: WorkflowWorkerRecord[]): string {
  const taken = new Set(workers.map((worker) => worker.nickname))
  if (!taken.has(baseNickname)) {
    return baseNickname
  }

  let suffix = 1
  while (taken.has(`${baseNickname}-${suffix}`)) {
    suffix += 1
  }

  return `${baseNickname}-${suffix}`
}

function collectSpawnRequests(args: {
  runId: string
  requests: SpawnRequest[]
  activeWorkers: WorkflowWorkerRecord[]
  satisfiedRequestIds: Set<string>
}): SpawnRequest[] {
  const activeKeys = new Set(args.activeWorkers.map(buildActiveWorkerKey))
  const latestByKey = new Map<string, SpawnRequest>()

  for (const request of args.requests) {
    if (request.runId !== args.runId || request.status !== 'open') {
      continue
    }

    const key = buildSpawnRequestKey(request)
    if (!key || activeKeys.has(key)) {
      continue
    }

    const isBlocked = request.dependsOn.some((dependsOnId) => !args.satisfiedRequestIds.has(dependsOnId))
    if (isBlocked) {
      continue
    }

    latestByKey.set(key, request)
  }

  return [...latestByKey.values()]
}

// A dependency is only "satisfied" once the worker spawned to fulfill it has
// actually stopped running — fulfillSpawnRequest fires at spawn time, before
// the worker has done any work, so status === 'fulfilled' alone isn't enough.
function computeSatisfiedRequestIds(args: {
  allRequests: SpawnRequest[]
  allWorkers: WorkflowWorkerRecord[]
}): Set<string> {
  const workerStatusById = new Map(args.allWorkers.map((worker) => [worker.workerId, worker.status]))

  return new Set(
    args.allRequests
      .filter((request) => {
        if (request.status !== 'fulfilled') {
          return false
        }
        if (!request.fulfilledWorkerId) {
          return true
        }
        return workerStatusById.get(request.fulfilledWorkerId) === 'stopped'
      })
      .map((request) => request.requestId)
  )
}

export function spawnRequestedWorkers(args: {
  runId: string
  workerRuntime: WorkerRuntimeLike
  bus: WorkflowBusLike
}): WorkflowWorkerRecord[] {
  const activeWorkers = args.workerRuntime.listWorkers({ runId: args.runId, activeOnly: true })
  const currentWorkers = args.workerRuntime.listWorkers({ runId: args.runId })
  const satisfiedRequestIds = computeSatisfiedRequestIds({
    allRequests: args.bus.listSpawnRequests(),
    allWorkers: currentWorkers,
  })
  const spawnRequests = collectSpawnRequests({
    runId: args.runId,
    requests: args.bus.listOpenSpawnRequests(),
    activeWorkers,
    satisfiedRequestIds,
  })
  const spawnedWorkers: WorkflowWorkerRecord[] = []

  for (const request of spawnRequests) {
    const role = request.requestedRole as WorkflowWorkerRecord['role']
    const nickname = buildUniqueNickname(buildWorkerNickname(role), [...currentWorkers, ...spawnedWorkers])
    const reason = `Bus request from ${request.askedBy} for ${request.scope}.`
    const prompt = buildRequestedWorkerPrompt({
      runId: args.runId,
      request,
    })

    const worker = args.workerRuntime.spawnWorker({
      runId: args.runId,
      role,
      nickname,
      reason,
      scope: request.scope,
      prompt,
    })

    spawnedWorkers.push(worker)
    args.bus.publishWorkerSpawned({
      runId: args.runId,
      owner: 'supervisor_loop',
      role,
      nickname,
      reason,
    })
    args.bus.fulfillSpawnRequest({
      requestId: request.requestId,
      fulfilledBy: 'supervisor_loop',
      fulfillmentNote: `Spawned worker ${nickname} (${role}).`,
      fulfilledWorkerId: worker.workerId,
    })
  }

  return spawnedWorkers
}

async function main(): Promise<number> {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    process.stdout.write(`${usage()}\n`)
    return 0
  }

  const options = parseArgs(process.argv.slice(2))
  const bus = createWorkflowBus({ storagePath: BUS_PATH })
  const workerRuntime = createWorkflowWorkerRuntime({
    rootDir: ROOT_DIR,
    outputDir: OUTPUT_DIR,
    processAdapter: createNodeWorkerProcessAdapter(),
    workerDriver: WORKER_DRIVER,
  })
  const workflowContext = buildWorkflowContext({
    rootDir: ROOT_DIR,
    frontDir: FRONT_DIR,
    outputDir: OUTPUT_DIR,
  })

  const latestRunStatus = [...bus.listRunStatuses()].sort((left, right) => left.at.localeCompare(right.at)).at(-1)
  const latestPersistedRun = resolveLatestPersistedRun(ORCHESTRATOR_STATE_DIR)
  const runId = options.runId ?? latestRunStatus?.runId ?? latestPersistedRun?.runId
  if (!runId) {
    process.stderr.write(`No runId was provided and no active run status exists in ${BUS_PATH}.\n`)
    return 1
  }

  const task = options.task ?? latestRunStatus?.summary ?? latestPersistedRun?.summary ?? `Continue supervising run ${runId}.`
  const scenario = options.scenario ?? (process.env.WORKFLOW_SCENARIO as SupervisorLoopOptions['scenario']) ?? 'both'
  const frontendUrl = options.frontendUrl ?? process.env.WORKFLOW_FRONTEND_URL ?? 'http://localhost:5174'

  process.stdout.write(`Supervisor loop starting for run ${runId}.\n`)
  process.stdout.write(`Scenario: ${scenario}. Frontend URL: ${frontendUrl}.\n`)
  process.stdout.write(`Workflow bus: ${BUS_PATH}\n`)

  let keepRunning = true
  let tickNumber = 0
  process.on('SIGINT', () => {
    keepRunning = false
    process.stdout.write('\nInterrupted; stopping supervisor loop.\n')
  })
  process.on('SIGTERM', () => {
    keepRunning = false
    process.stdout.write('\nTermination requested; stopping supervisor loop.\n')
  })

  while (keepRunning) {
    tickNumber += 1
    const previousState = readOrchestratorState(workflowContext, runId)
    const orchestratorResult = runOrchestratorTurn({
      runId,
      task,
      scenario,
      frontendUrl,
      workerRuntime,
      bus,
      staleAfterMs: options.staleAfterMs,
      previousState,
    })
    writeOrchestratorState(workflowContext, orchestratorResult.nextState)
    appendOrchestratorTickHistory(workflowContext, orchestratorResult.nextState)

    const persistedState = readOrchestratorState(workflowContext, runId)
    const spawnedWorkers = spawnRequestedWorkers({ runId, workerRuntime, bus })
    const openSpawnRequests = bus.listOpenSpawnRequests().filter((request) => request.runId === runId).length
    const activeWorkers = workerRuntime.listWorkers({ runId, activeOnly: true }).length
    const spawnedRoles = spawnedWorkers.map((worker) => worker.role).join(', ') || 'none'

    process.stdout.write(
      [
        `tick=${tickNumber}`,
        `stateTick=${persistedState.tickCount}`,
        `phase=${persistedState.phase}`,
        `spawned=${spawnedRoles}`,
        `openSpawnRequests=${openSpawnRequests}`,
        `activeWorkers=${activeWorkers}`,
      ].join(' | ') + '\n'
    )

    if (options.once || !keepRunning) {
      break
    }

    process.stdout.write(`Sleeping ${options.intervalMs}ms before the next supervisor tick.\n`)
    await sleep(options.intervalMs)
  }

  return 0
}

const isMain =
  typeof process !== 'undefined' &&
  Array.isArray(process.argv) &&
  import.meta.url === `file://${process.argv[1]}`

if (isMain) {
  main()
    .then((exitCode) => {
      process.exitCode = exitCode
    })
    .catch((error: unknown) => {
      const message = error instanceof Error ? error.stack ?? error.message : String(error)
      process.stderr.write(`${message}\n`)
      process.exitCode = 1
    })
}
