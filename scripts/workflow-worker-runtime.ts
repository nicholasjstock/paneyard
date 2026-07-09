import { createId } from './workflow-worker-spawn'
import type { WorkflowAgent } from './workflow-mcp'

// Re-exported so existing importers (e.g. supervisor-loop.ts) keep working
// unchanged — createId's actual home is workflow-worker-spawn.ts, shared
// between spawn logic and the Rails-backed runtime.
export { createId }

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

export type WorkerExitStatus = {
  code: number | null
  signal: NodeJS.Signals | null
}

export type WorkerProcessAdapter = {
  spawn: (command: string, args: string[], options: WorkerSpawnOptions) => WorkerProcessHandle
  isAlive: (pid: number) => boolean
  kill: (pid: number, signal?: NodeJS.Signals | number) => void
  // Real exit code/signal for a pid that has actually exited, if the adapter
  // is able to observe it. Optional so adapters that can't report this
  // (test fakes, older adapters) still work — callers fall back to a
  // best-effort guess from the worker's own log when this returns null.
  getExitStatus?: (pid: number) => WorkerExitStatus | null
}

export type SpawnWorkerArgs = {
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

export type ListWorkersArgs = {
  runId?: string
  activeOnly?: boolean
}

export type StopWorkerArgs =
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

// Satisfied by workflow-worker-runtime-rails.ts's createWorkflowWorkerRuntimeRails
// -- the only implementation now that the JSON-file backend has been
// retired. Actual process spawning/killing/liveness-checking stays local
// regardless (only Node can fork/observe a local subprocess) -- see
// workflow-worker-spawn.ts.
export type WorkflowWorkerRuntime = {
  spawnWorker: (args: SpawnWorkerArgs) => Promise<WorkflowWorkerRecord>
  listWorkers: (args?: ListWorkersArgs) => Promise<WorkflowWorkerRecord[]>
  stopWorker: (args: StopWorkerArgs) => Promise<WorkflowWorkerRecord>
}
