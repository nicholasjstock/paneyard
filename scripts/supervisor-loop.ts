import { spawnSync } from 'child_process'
import * as path from 'path'
import { fileURLToPath } from 'url'

import { buildRequestedWorkerPrompt, buildWorkerNickname } from './orchestrator-turn'
import { buildWorkflowContext, readOrchestratorState } from './workflow-mcp'
import { createWorkflowBus } from './workflow-bus'
import { createNodeWorkerProcessAdapter } from './workflow-worker-runtime-node'
import { createWorkflowWorkerRuntime, type WorkflowWorkerRecord } from './workflow-worker-runtime'

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
}

type WorkerRuntimeLike = Pick<ReturnType<typeof createWorkflowWorkerRuntime>, 'listWorkers' | 'spawnWorker'>
type WorkflowBusLike = Pick<
  ReturnType<typeof createWorkflowBus>,
  'listOpenSpawnRequests' | 'publishWorkerSpawned' | 'fulfillSpawnRequest'
>

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// PKG_ROOT: this package's own install location (where bin/orchestrator_launcher lives).
const PKG_ROOT = path.resolve(__dirname, '..')
// ROOT_DIR: the project being orchestrated (e.g. simple-retail-planner). See
// workflow-mcp-app.ts for the same pattern/rationale.
const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT ? path.resolve(process.env.WORKFLOW_TARGET_ROOT) : PKG_ROOT
const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
const OUTPUT_DIR = process.env.WORKFLOW_STATE_DIR
  ? path.resolve(process.env.WORKFLOW_STATE_DIR)
  : path.resolve(FRONT_DIR, 'demo-output', 'agents-sdk')
const BUS_PATH = path.join(OUTPUT_DIR, 'workflow-bus.json')

export function resolveOrchestratorLauncher(env: NodeJS.ProcessEnv, rootDir: string): string {
  return env.ORCHESTRATOR_LAUNCHER
    ? path.resolve(env.ORCHESTRATOR_LAUNCHER)
    : path.join(rootDir, 'bin', 'orchestrator_launcher')
}

// orchestrator_launcher ships inside this package, not inside the target
// project, so resolve it against PKG_ROOT rather than ROOT_DIR.
const ORCHESTRATOR_LAUNCHER = resolveOrchestratorLauncher(process.env, PKG_ROOT)

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

    latestByKey.set(key, request)
  }

  return [...latestByKey.values()]
}

export function spawnRequestedWorkers(args: {
  runId: string
  workerRuntime: WorkerRuntimeLike
  bus: WorkflowBusLike
}): WorkflowWorkerRecord[] {
  const activeWorkers = args.workerRuntime.listWorkers({ runId: args.runId, activeOnly: true })
  const spawnRequests = collectSpawnRequests({
    runId: args.runId,
    requests: args.bus.listOpenSpawnRequests(),
    activeWorkers,
  })
  const currentWorkers = args.workerRuntime.listWorkers({ runId: args.runId })
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
    })
  }

  return spawnedWorkers
}

function runOrchestratorSubprocess(args: {
  runId: string
  task: string
  scenario: NonNullable<SupervisorLoopOptions['scenario']>
  frontendUrl: string
  staleAfterMs?: number
}): { exitCode: number; stdout: string; stderr: string } {
  const result = spawnSync(
    ORCHESTRATOR_LAUNCHER,
    [
      `--run-id=${args.runId}`,
      `--task=${args.task}`,
      `--scenario=${args.scenario}`,
      `--frontend-url=${args.frontendUrl}`,
      ...(args.staleAfterMs ? [`--stale-after-ms=${args.staleAfterMs}`] : []),
    ],
    {
      cwd: ROOT_DIR,
      encoding: 'utf8',
      env: process.env,
    }
  )

  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  }
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
  })

  const latestRunStatus = [...bus.listRunStatuses()].sort((left, right) => left.at.localeCompare(right.at)).at(-1)
  const runId = options.runId ?? latestRunStatus?.runId
  if (!runId) {
    process.stderr.write(`No runId was provided and no active run status exists in ${BUS_PATH}.\n`)
    return 1
  }

  const task = options.task ?? latestRunStatus?.summary ?? `Continue supervising run ${runId}.`
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
    const orchestratorResult = runOrchestratorSubprocess({
      runId,
      task,
      scenario,
      frontendUrl,
      staleAfterMs: options.staleAfterMs,
    })
    if (orchestratorResult.stdout.trim().length > 0) {
      process.stdout.write(orchestratorResult.stdout)
      if (!orchestratorResult.stdout.endsWith('\n')) {
        process.stdout.write('\n')
      }
    }

    if (orchestratorResult.exitCode !== 0) {
      if (orchestratorResult.stderr.trim().length > 0) {
        process.stderr.write(orchestratorResult.stderr)
        if (!orchestratorResult.stderr.endsWith('\n')) {
          process.stderr.write('\n')
        }
      }
      process.stderr.write(`Orchestrator tick failed with exit code ${orchestratorResult.exitCode}.\n`)
      return orchestratorResult.exitCode
    }

    const persistedState = readOrchestratorState(
      buildWorkflowContext({
        rootDir: ROOT_DIR,
        frontDir: FRONT_DIR,
        outputDir: OUTPUT_DIR,
      }),
      runId
    )
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
