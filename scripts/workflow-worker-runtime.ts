import * as fs from 'fs'
import * as path from 'path'

import { formatWorkflowWorkerLifecycleLine } from './workflow-worker-logging'
import { buildWorkerPromptWithPersona } from './agent-persona'
import type { WorkflowAgent } from './workflow-mcp'

export type WorkflowManagedRole = WorkflowAgent | 'planner'
export type WorkflowWorkerStatus = 'running' | 'stopped'
export type WorkerDriver = 'codex' | 'claude'

export type WorkflowWorkerRecord = {
  workerId: string
  runId: string
  role: WorkflowManagedRole
  nickname: string
  reason: string
  scope: string
  status: WorkflowWorkerStatus
  pid: number
  promptPath: string
  logPath: string
  lastMessagePath: string
  envPath: string
  command: string
  args: string[]
  startedAt: string
  stoppedAt: string | null
  stopReason: string | null
}

type PersistedWorkerState = {
  workers: WorkflowWorkerRecord[]
}

type RuntimeFileSystem = {
  mkdirSync(dir: string, options?: { recursive?: boolean }): void
  writeFileSync(filePath: string, content: string): void
  appendFileSync(filePath: string, content: string): void
  readFileSync(filePath: string, encoding?: BufferEncoding): string
  existsSync(filePath: string): boolean
}

const defaultRuntimeFileSystem: RuntimeFileSystem = {
  mkdirSync(dir, options) {
    fs.mkdirSync(dir, options)
  },
  writeFileSync(filePath, content) {
    fs.writeFileSync(filePath, content)
  },
  appendFileSync(filePath, content) {
    fs.appendFileSync(filePath, content)
  },
  readFileSync(filePath, encoding = 'utf8') {
    return fs.readFileSync(filePath, encoding)
  },
  existsSync(filePath) {
    return fs.existsSync(filePath)
  },
}

type WorkerSpawnOptions = {
  cwd: string
  detached?: boolean
  env?: NodeJS.ProcessEnv
  logPath?: string
}

type WorkerProcessHandle = {
  pid: number
  stdin?: {
    write: (chunk: string) => void
    end: (chunk?: string) => void
  }
  unref?: () => void
}

export type WorkerProcessAdapter = {
  spawn: (command: string, args: string[], options: WorkerSpawnOptions) => WorkerProcessHandle
  isAlive: (pid: number) => boolean
  kill: (pid: number, signal?: NodeJS.Signals | number) => void
}

type CreateWorkerRuntimeArgs = {
  rootDir: string
  outputDir: string
  storagePath?: string
  fileSystem?: RuntimeFileSystem
  processAdapter: WorkerProcessAdapter
  workerDriver?: WorkerDriver
}

type SpawnWorkerArgs = {
  runId: string
  role: WorkflowManagedRole
  nickname: string
  reason: string
  scope: string
  prompt: string
  // Lets a caller (the supervisor loop) claim this worker's id on the bus
  // before the worker actually exists, shrinking the window in which a
  // concurrently-running claim check can't yet see it. Falls back to
  // generating one here for callers that don't need that guarantee.
  workerId?: string
}

type ListWorkersArgs = {
  runId?: string
  activeOnly?: boolean
}

type StopWorkerArgs =
  | {
      workerId: string
      nickname?: never
      reason: string
    }
  | {
      workerId?: never
      nickname: string
      reason: string
    }

export type WorkflowWorkerRuntime = {
  spawnWorker: (args: SpawnWorkerArgs) => WorkflowWorkerRecord
  listWorkers: (args?: ListWorkersArgs) => WorkflowWorkerRecord[]
  stopWorker: (args: StopWorkerArgs) => WorkflowWorkerRecord
}

export function createId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID()
  }

  return `worker-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function resolvePath(baseDir: string, suffix: string): string {
  return `${baseDir.replace(/\/$/, '')}/${suffix}`
}

function cloneWorker(worker: WorkflowWorkerRecord): WorkflowWorkerRecord {
  return {
    ...worker,
    args: [...worker.args],
  }
}

function resolveCodexHome(): string | undefined {
  const homeDir = process.env.HOME
  const defaultCodexHome =
    process.env.XDG_CONFIG_HOME
      ? path.join(process.env.XDG_CONFIG_HOME, 'codex')
      : homeDir
        ? path.join(homeDir, '.config', 'codex')
        : undefined

  const configuredCodexHome = process.env.CODEX_HOME
  const hasAuthJson = (codexHome: string | undefined) =>
    typeof codexHome === 'string' && fs.existsSync(path.join(codexHome, 'auth.json'))

  if (hasAuthJson(configuredCodexHome)) {
    return configuredCodexHome
  }

  if (hasAuthJson(defaultCodexHome)) {
    return defaultCodexHome
  }

  return configuredCodexHome ?? defaultCodexHome
}

function readCodexAuthApiKey(codexHome: string | undefined): string | undefined {
  if (!codexHome) {
    return undefined
  }

  const authPath = path.join(codexHome, 'auth.json')
  if (!fs.existsSync(authPath)) {
    return undefined
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(authPath, 'utf8')) as {
      OPENAI_API_KEY?: unknown
      tokens?: { access_token?: unknown }
    }

    if (typeof parsed.OPENAI_API_KEY === 'string' && parsed.OPENAI_API_KEY.trim() !== '') {
      return parsed.OPENAI_API_KEY
    }

    if (typeof parsed.tokens?.access_token === 'string' && parsed.tokens.access_token.trim() !== '') {
      return parsed.tokens.access_token
    }

    return undefined
  } catch {
    return undefined
  }
}

function buildWorkerEnv(): NodeJS.ProcessEnv {
  const homeDir = process.env.HOME
  const codexHome = resolveCodexHome()
  const workerEnv: NodeJS.ProcessEnv = {
    ...process.env,
    HOME: homeDir,
    PATH: process.env.PATH,
  }

  if (codexHome) {
    workerEnv.CODEX_HOME = codexHome
  }

  if (!workerEnv.OPENAI_API_KEY) {
    const authApiKey = readCodexAuthApiKey(codexHome)
    if (authApiKey) {
      workerEnv.OPENAI_API_KEY = authApiKey
    }
  }

  const maskedApiKey = workerEnv.OPENAI_API_KEY?.trim().toLowerCase()
  if (maskedApiKey === '' || maskedApiKey === '[set]' || maskedApiKey === '[secure]' || maskedApiKey === '[redacted]') {
    delete workerEnv.OPENAI_API_KEY
  }

  return workerEnv
}

function buildWorkerEnvSnapshot(env: NodeJS.ProcessEnv): Record<string, string | null> {
  const pick = (key: string) => env[key] ?? null

  return {
    HOME: pick('HOME'),
    CODEX_HOME: pick('CODEX_HOME'),
    PATH: pick('PATH'),
    SHELL: pick('SHELL'),
    USER: pick('USER'),
    LOGNAME: pick('LOGNAME'),
    TMPDIR: pick('TMPDIR'),
    OPENAI_API_KEY: pick('OPENAI_API_KEY') ? '[set]' : null,
    OPENAI_BASE_URL: pick('OPENAI_BASE_URL'),
  }
}

function readUnexpectedExitReason(fileSystem: RuntimeFileSystem, worker: WorkflowWorkerRecord): string {
  if (!fileSystem.existsSync(worker.logPath)) {
    return 'Process exited before an explicit stop was recorded.'
  }

  try {
    const logContents = fileSystem.readFileSync(worker.logPath, 'utf8')
    const lines = logContents
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)

    const usefulLine =
      [...lines]
        .reverse()
        .find((line) => !line.includes('worker:lifecycle') && /error|unauthorized|failed|exception/i.test(line)) ??
      [...lines].reverse().find((line) => !line.includes('worker:lifecycle'))

    if (!usefulLine) {
      return 'Process exited before an explicit stop was recorded.'
    }

    return `Process exited unexpectedly. Last log error: ${usefulLine}`
  } catch {
    return 'Process exited before an explicit stop was recorded.'
  }
}

function appendWorkerLogLine(fileSystem: RuntimeFileSystem, logPath: string, line: string): void {
  fileSystem.appendFileSync(logPath, `${line}\n`)
}

export function createWorkflowWorkerRuntime(
  args: CreateWorkerRuntimeArgs
): WorkflowWorkerRuntime {
  const fileSystem = args.fileSystem ?? defaultRuntimeFileSystem
  const processAdapter = args.processAdapter
  const storagePath = args.storagePath ?? resolvePath(args.outputDir, 'workers.json')
  const workersDir = resolvePath(args.outputDir, 'workers')

  const ensureDir = () => {
    fileSystem.mkdirSync(args.outputDir, { recursive: true })
    fileSystem.mkdirSync(workersDir, { recursive: true })
  }

  const loadWorkers = (): WorkflowWorkerRecord[] => {
    if (!fileSystem.existsSync(storagePath)) {
      return []
    }

    try {
      const parsed = JSON.parse(fileSystem.readFileSync(storagePath, 'utf8')) as PersistedWorkerState
      return parsed.workers.map((worker) => ({
        ...worker,
        args: [...worker.args],
      }))
    } catch {
      return []
    }
  }

  const persistWorkers = (workers: WorkflowWorkerRecord[]) => {
    ensureDir()
    const payload: PersistedWorkerState = {
      workers: workers.map(cloneWorker),
    }
    fileSystem.writeFileSync(storagePath, `${JSON.stringify(payload, null, 2)}\n`)
  }

  const refreshWorkers = (workers: WorkflowWorkerRecord[]) => {
    let changed = false

    for (const worker of workers) {
      if (worker.status !== 'running') {
        continue
      }

      if (processAdapter.isAlive(worker.pid)) {
        continue
      }

      worker.status = 'stopped'
      worker.stoppedAt = new Date().toISOString()
      worker.stopReason = worker.stopReason ?? readUnexpectedExitReason(fileSystem, worker)
      appendWorkerLogLine(
        fileSystem,
        worker.logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: worker.stoppedAt,
          event: 'stopped',
          workerId: worker.workerId,
          runId: worker.runId,
          role: worker.role,
          nickname: worker.nickname,
          pid: worker.pid,
          scope: worker.scope,
          reason: worker.reason,
          command: worker.command,
          status: worker.status,
          stopReason: worker.stopReason,
        })
      )
      changed = true
    }

    if (changed) {
      persistWorkers(workers)
    }
  }

  const findWorker = (workers: WorkflowWorkerRecord[], args: StopWorkerArgs) => {
    return workers.find((worker) =>
      'workerId' in args ? worker.workerId === args.workerId : worker.nickname === args.nickname
    )
  }

  const workerDriver: WorkerDriver = args.workerDriver ?? 'codex'

  return {
    spawnWorker(spawnArgs) {
      ensureDir()
      const workerId = spawnArgs.workerId ?? createId()
      const promptPath = resolvePath(workersDir, `${spawnArgs.nickname}.prompt.txt`)
      const logPath = resolvePath(workersDir, `${spawnArgs.nickname}.log`)
      const lastMessagePath = resolvePath(workersDir, `${spawnArgs.nickname}.last-message.txt`)
      const envPath = resolvePath(workersDir, `${spawnArgs.nickname}.env.json`)
      const workerEnv = buildWorkerEnv()

      // The claude CLI resolves `--agent <role>` against .claude/agents/<role>.md
      // itself, so the persona must not also be prepended into the prompt the
      // way it is for codex (which has no equivalent named-agent mechanism).
      const command = workerDriver === 'claude' ? 'claude' : 'codex'
      const enrichedPrompt =
        workerDriver === 'claude'
          ? spawnArgs.prompt
          : buildWorkerPromptWithPersona({
              rootDir: args.rootDir,
              role: spawnArgs.role,
              prompt: spawnArgs.prompt,
            })
      const commandArgs =
        workerDriver === 'claude'
          ? ['--agent', spawnArgs.role, '--permission-mode', 'bypassPermissions', '-p', '--', enrichedPrompt]
          : ['exec', '--dangerously-bypass-approvals-and-sandbox', '-C', args.rootDir, '-o', lastMessagePath, '-']

      fileSystem.writeFileSync(promptPath, enrichedPrompt)
      fileSystem.writeFileSync(logPath, '')
      fileSystem.writeFileSync(`${envPath}`, `${JSON.stringify(buildWorkerEnvSnapshot(workerEnv), null, 2)}\n`)

      const child = processAdapter.spawn(command, commandArgs, {
        cwd: args.rootDir,
        detached: true,
        env: workerEnv,
        logPath,
      })

      if (workerDriver === 'claude') {
        child.stdin?.end()
      } else {
        child.stdin?.end(enrichedPrompt)
      }
      child.unref?.()

      const worker: WorkflowWorkerRecord = {
        workerId,
        runId: spawnArgs.runId,
        role: spawnArgs.role,
        nickname: spawnArgs.nickname,
        reason: spawnArgs.reason,
        scope: spawnArgs.scope,
        status: 'running',
        pid: child.pid,
        promptPath,
        logPath,
        lastMessagePath,
        envPath,
        command,
        args: commandArgs,
        startedAt: new Date().toISOString(),
        stoppedAt: null,
        stopReason: null,
      }

      appendWorkerLogLine(
        fileSystem,
        logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: worker.startedAt,
          event: 'spawned',
          workerId,
          runId: spawnArgs.runId,
          role: spawnArgs.role,
          nickname: spawnArgs.nickname,
          pid: worker.pid,
          scope: spawnArgs.scope,
          reason: spawnArgs.reason,
          command,
          status: worker.status,
        })
      )

      const workers = loadWorkers()
      workers.push(worker)
      persistWorkers(workers)
      return cloneWorker(worker)
    },

    listWorkers(listArgs = {}) {
      const workers = loadWorkers()
      refreshWorkers(workers)

      return workers
        .filter((worker) => (listArgs.runId ? worker.runId === listArgs.runId : true))
        .filter((worker) => (listArgs.activeOnly ? worker.status === 'running' : true))
        .map(cloneWorker)
    },

    stopWorker(stopArgs) {
      const workers = loadWorkers()
      refreshWorkers(workers)
      const worker = findWorker(workers, stopArgs)

      if (!worker) {
        throw new Error(
          'workerId' in stopArgs
            ? `Unknown worker: ${stopArgs.workerId}`
            : `Unknown worker nickname: ${stopArgs.nickname}`
        )
      }

      if (worker.status === 'running' && processAdapter.isAlive(worker.pid)) {
        processAdapter.kill(worker.pid, 'SIGTERM')
      }

      worker.status = 'stopped'
      worker.stoppedAt = new Date().toISOString()
      worker.stopReason = stopArgs.reason
      appendWorkerLogLine(
        fileSystem,
        worker.logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: worker.stoppedAt,
          event: 'stopped',
          workerId: worker.workerId,
          runId: worker.runId,
          role: worker.role,
          nickname: worker.nickname,
          pid: worker.pid,
          scope: worker.scope,
          reason: worker.reason,
          command: worker.command,
          status: worker.status,
          stopReason: worker.stopReason,
        })
      )
      persistWorkers(workers)

      return cloneWorker(worker)
    },
  }
}
