import * as fs from 'fs'

import { createWorkflowWorkerRuntime, type WorkflowWorkerRecord } from './workflow-worker-runtime'
import { createNodeWorkerProcessAdapter } from './workflow-worker-runtime-node'

type MonitorArgs = {
  storagePath?: string
  workerId?: string
  nickname?: string
  tail?: number
  json?: boolean
}

type WorkerMonitorSnapshot = {
  storagePath: string
  exists: boolean
  workers: WorkflowWorkerRecord[]
  selectedWorker: WorkflowWorkerRecord | null
  selectedWorkerLogTail: string | null
  selectedWorkerLastMessage: string | null
}

const nodeRuntimeFileSystem = {
  mkdirSync(dir: string, options?: { recursive?: boolean }) {
    fs.mkdirSync(dir, options)
  },
  writeFileSync(filePath: string, content: string) {
    fs.writeFileSync(filePath, content)
  },
  appendFileSync(filePath: string, content: string) {
    fs.appendFileSync(filePath, content)
  },
  readFileSync(filePath: string, encoding: BufferEncoding = 'utf8') {
    return fs.readFileSync(filePath, encoding)
  },
  existsSync(filePath: string) {
    return fs.existsSync(filePath)
  },
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '')
}

function resolveDefaultStoragePath(): string {
  return `${trimTrailingSlash(process.cwd())}/demo-output/agents-sdk/workers.json`
}

function readTail(filePath: string, lineCount: number): string | null {
  if (!fs.existsSync(filePath)) {
    return null
  }

  const contents = fs.readFileSync(filePath, 'utf8')
  const lines = contents.split(/\r?\n/)
  const tail = lines.slice(Math.max(0, lines.length - lineCount)).filter(Boolean)
  return tail.length > 0 ? `${tail.join('\n')}\n` : null
}

function formatWorkerSummary(worker: WorkflowWorkerRecord): string {
  const parts = [
    `- ${worker.nickname}`,
    `[${worker.status}]`,
    `role=${worker.role}`,
    `pid=${worker.pid}`,
    `runId=${worker.runId}`,
    `log=${worker.logPath}`,
    `last=${worker.lastMessagePath}`,
  ]

  if (worker.stopReason) {
    parts.push(`stop=${worker.stopReason}`)
  }

  return parts.join(' ')
}

function formatWorkerDetail(snapshot: WorkerMonitorSnapshot, tailLines: number): string {
  const worker = snapshot.selectedWorker
  if (!worker) {
    return `Worker not found.\n`
  }

  const lines = [
    `Worker: ${worker.nickname}`,
    `Role: ${worker.role}`,
    `Status: ${worker.status}`,
    `PID: ${worker.pid}`,
    `Run: ${worker.runId}`,
    `Log: ${worker.logPath}`,
    `Prompt: ${worker.promptPath}`,
    `Last message: ${worker.lastMessagePath}`,
    `Started: ${worker.startedAt}`,
  ]

  if (worker.stoppedAt) {
    lines.push(`Stopped: ${worker.stoppedAt}`)
  }

  if (worker.stopReason) {
    lines.push(`Stop reason: ${worker.stopReason}`)
  }

  const logTail = snapshot.selectedWorkerLogTail
  if (logTail) {
    lines.push('', `Recent log (${tailLines} lines):`, logTail.trimEnd())
  }

  const lastMessage = snapshot.selectedWorkerLastMessage
  if (lastMessage) {
    lines.push('', 'Latest message:', lastMessage.trimEnd())
  }

  return `${lines.join('\n')}\n`
}

export function resolveWorkflowWorkerLogPath(args: MonitorArgs = {}): string | null {
  const storagePath = args.storagePath ?? resolveDefaultStoragePath()
  const runtime = createWorkflowWorkerRuntime({
    rootDir: process.cwd(),
    outputDir: `${process.cwd().replace(/\/$/, '')}/demo-output/agents-sdk`,
    storagePath,
    fileSystem: nodeRuntimeFileSystem,
    processAdapter: createNodeWorkerProcessAdapter(),
  })

  const workers = runtime.listWorkers()
  const selectedWorker =
    (args.workerId ? workers.find((worker) => worker.workerId === args.workerId) : null) ??
    (args.nickname ? workers.find((worker) => worker.nickname === args.nickname) : null) ??
    null

  return selectedWorker?.logPath ?? null
}

export function inspectWorkflowWorkers(args: MonitorArgs = {}): string {
  const storagePath = args.storagePath ?? resolveDefaultStoragePath()
  const runtime = createWorkflowWorkerRuntime({
    rootDir: process.cwd(),
    outputDir: `${process.cwd().replace(/\/$/, '')}/demo-output/agents-sdk`,
    storagePath,
    fileSystem: nodeRuntimeFileSystem,
    processAdapter: createNodeWorkerProcessAdapter(),
  })

  const workers = runtime.listWorkers()
  const selectedWorker =
    (args.workerId ? workers.find((worker) => worker.workerId === args.workerId) : null) ??
    (args.nickname ? workers.find((worker) => worker.nickname === args.nickname) : null) ??
    null
  const tailLines = args.tail ?? 40

  return formatWorkerDetail(
    {
      storagePath,
      exists: fs.existsSync(storagePath),
      workers,
      selectedWorker,
      selectedWorkerLogTail: selectedWorker ? readTail(selectedWorker.logPath, tailLines) : null,
      selectedWorkerLastMessage: selectedWorker && fs.existsSync(selectedWorker.lastMessagePath)
        ? `${fs.readFileSync(selectedWorker.lastMessagePath, 'utf8')}\n`
        : null,
    },
    tailLines
  )
}

export function inspectWorkflowWorkersList(args: MonitorArgs = {}): string {
  const storagePath = args.storagePath ?? resolveDefaultStoragePath()
  const runtime = createWorkflowWorkerRuntime({
    rootDir: process.cwd(),
    outputDir: `${process.cwd().replace(/\/$/, '')}/demo-output/agents-sdk`,
    storagePath,
    fileSystem: nodeRuntimeFileSystem,
    processAdapter: createNodeWorkerProcessAdapter(),
  })

  const workers = runtime.listWorkers()
  const lines = [
    `Workflow workers: ${storagePath}`,
    `Exists: ${fs.existsSync(storagePath) ? 'yes' : 'no'}`,
    `Workers: ${workers.length}`,
  ]

  for (const worker of workers) {
    lines.push(formatWorkerSummary(worker))
  }

  return `${lines.join('\n')}\n`
}

const isMain =
  typeof process !== 'undefined' &&
  Array.isArray(process.argv) &&
  import.meta.url === `file://${process.argv[1]}`

if (isMain) {
  const storagePath = process.argv.includes('--path')
    ? process.argv[process.argv.indexOf('--path') + 1]
    : undefined
  const tail = process.argv.includes('--tail') ? Number(process.argv[process.argv.indexOf('--tail') + 1]) : undefined
  const workerId = process.argv.includes('--worker-id')
    ? process.argv[process.argv.indexOf('--worker-id') + 1]
    : undefined
  const nickname = process.argv.includes('--nickname')
    ? process.argv[process.argv.indexOf('--nickname') + 1]
    : undefined
  const logPathOnly = process.argv.includes('--log-path')

  const hasWorkerSelection = Boolean(workerId || nickname)
  process.stdout.write(
    logPathOnly
      ? `${resolveWorkflowWorkerLogPath({
          storagePath,
          workerId,
          nickname,
        }) ?? ''}\n`
      : hasWorkerSelection
      ? inspectWorkflowWorkers({
          storagePath,
          workerId,
          nickname,
          tail: Number.isFinite(tail) ? tail : undefined,
        })
      : inspectWorkflowWorkersList({
          storagePath,
        })
  )
}
