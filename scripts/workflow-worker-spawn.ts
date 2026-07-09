import * as fs from 'fs'
import * as path from 'path'

import { formatWorkflowWorkerLifecycleLine } from './workflow-worker-logging'
import { buildWorkerPromptWithPersona } from './agent-persona'
import type { WorkerDriver, WorkerExitStatus, WorkerProcessAdapter, WorkflowManagedRole, WorkflowWorkerRecord } from './workflow-worker-runtime'

// Shared between the JSON-backed and Rails-backed worker runtimes: actually
// forking a worker process, and describing why one already exited, is
// local-only regardless of which backend is persisting the registry (only
// Node can fork/observe a local subprocess), so both backends call these
// same functions and differ only in how they persist the resulting
// WorkflowWorkerRecord afterward.

export function createId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID()
  }

  return `worker-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function resolvePath(baseDir: string, suffix: string): string {
  return `${baseDir.replace(/\/$/, '')}/${suffix}`
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

export type WorkerSpawnFileSystem = {
  writeFileSync(filePath: string, content: string): void
  appendFileSync(filePath: string, content: string): void
  readFileSync(filePath: string, encoding?: BufferEncoding): string
  existsSync(filePath: string): boolean
}

function findLastUsefulLogLine(fileSystem: WorkerSpawnFileSystem, worker: WorkflowWorkerRecord): string | null {
  if (!fileSystem.existsSync(worker.logPath)) {
    return null
  }

  try {
    const logContents = fileSystem.readFileSync(worker.logPath, 'utf8')
    const lines = logContents
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)

    return (
      [...lines]
        .reverse()
        .find((line) => !line.includes('worker:lifecycle') && /error|unauthorized|failed|exception/i.test(line)) ??
      [...lines].reverse().find((line) => !line.includes('worker:lifecycle')) ??
      null
    )
  } catch {
    return null
  }
}

// Fallback used only when the process adapter can't report a real exit
// code/signal (no getExitStatus support, or the exit event hasn't been
// observed yet) — best-effort guess from the worker's own log, same
// heuristic used before real exit-status capture existed.
export function readUnexpectedExitReason(fileSystem: WorkerSpawnFileSystem, worker: WorkflowWorkerRecord): string {
  const usefulLine = findLastUsefulLogLine(fileSystem, worker)
  if (!usefulLine) {
    return 'Process exited before an explicit stop was recorded.'
  }

  return `Process exited unexpectedly. Last log error: ${usefulLine}`
}

export function describeWorkerExit(
  fileSystem: WorkerSpawnFileSystem,
  worker: WorkflowWorkerRecord,
  exitStatus: WorkerExitStatus | null
): string {
  if (!exitStatus) {
    return readUnexpectedExitReason(fileSystem, worker)
  }

  if (exitStatus.signal == null && exitStatus.code === 0) {
    return 'Process exited cleanly (code 0).'
  }

  const cause = exitStatus.signal ? `killed by signal ${exitStatus.signal}` : `exited with code ${exitStatus.code}`
  const lastLine = findLastUsefulLogLine(fileSystem, worker)
  return lastLine ? `Process ${cause}. Last log line: ${lastLine}` : `Process ${cause}.`
}

export function appendWorkerLogLine(fileSystem: WorkerSpawnFileSystem, logPath: string, line: string): void {
  fileSystem.appendFileSync(logPath, `${line}\n`)
}

export type SpawnWorkerProcessArgs = {
  runId: string
  role: WorkflowManagedRole
  nickname: string
  reason: string
  scope: string
  prompt: string
  // See SpawnWorkerArgs.workerId in workflow-worker-runtime.ts — lets a
  // caller claim this id before the worker exists.
  workerId?: string
}

export type SpawnWorkerProcessContext = {
  rootDir: string
  workersDir: string
  workerDriver: WorkerDriver
  fileSystem: WorkerSpawnFileSystem
  processAdapter: WorkerProcessAdapter
}

export function spawnWorkerProcess(
  context: SpawnWorkerProcessContext,
  spawnArgs: SpawnWorkerProcessArgs
): WorkflowWorkerRecord {
  const workerId = spawnArgs.workerId ?? createId()
  const promptPath = resolvePath(context.workersDir, `${spawnArgs.nickname}.prompt.txt`)
  const logPath = resolvePath(context.workersDir, `${spawnArgs.nickname}.log`)
  const lastMessagePath = resolvePath(context.workersDir, `${spawnArgs.nickname}.last-message.txt`)
  const envPath = resolvePath(context.workersDir, `${spawnArgs.nickname}.env.json`)
  const workerEnv = buildWorkerEnv()

  // The claude CLI resolves `--agent <role>` against .claude/agents/<role>.md
  // itself, so the persona must not also be prepended into the prompt the
  // way it is for codex (which has no equivalent named-agent mechanism).
  const command = context.workerDriver === 'claude' ? 'claude' : 'codex'
  const enrichedPrompt =
    context.workerDriver === 'claude'
      ? spawnArgs.prompt
      : buildWorkerPromptWithPersona({
          rootDir: context.rootDir,
          role: spawnArgs.role,
          prompt: spawnArgs.prompt,
        })
  const commandArgs =
    context.workerDriver === 'claude'
      ? ['--agent', spawnArgs.role, '--permission-mode', 'bypassPermissions', '-p', '--', enrichedPrompt]
      : ['exec', '--dangerously-bypass-approvals-and-sandbox', '-C', context.rootDir, '-o', lastMessagePath, '-']

  context.fileSystem.writeFileSync(promptPath, enrichedPrompt)
  context.fileSystem.writeFileSync(logPath, '')
  context.fileSystem.writeFileSync(envPath, `${JSON.stringify(buildWorkerEnvSnapshot(workerEnv), null, 2)}\n`)

  const child = context.processAdapter.spawn(command, commandArgs, {
    cwd: context.rootDir,
    detached: true,
    env: workerEnv,
    logPath,
  })

  if (context.workerDriver === 'claude') {
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

  context.fileSystem.appendFileSync(
    logPath,
    `${formatWorkflowWorkerLifecycleLine({
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
    })}\n`
  )

  return worker
}
