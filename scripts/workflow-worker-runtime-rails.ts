import * as fs from 'fs'

import { railsGet, railsPost, type RailsApiRequestOptions } from './rails-api-client'
import { appendWorkerLogLine, describeWorkerExit, spawnWorkerProcess, type WorkerSpawnFileSystem } from './workflow-worker-spawn'
import { formatWorkflowWorkerLifecycleLine } from './workflow-worker-logging'
import type { WorkerDriver, WorkerProcessAdapter, WorkflowWorkerRecord, WorkflowWorkerRuntime } from './workflow-worker-runtime'

// HTTP-backed implementation of WorkflowWorkerRuntime (workflow-worker-runtime.ts),
// satisfying the exact same type. Per the plan's "Rails-side worker liveness"
// section: actually forking/observing a local worker process can only ever
// happen on the host running the supervisor loop, so spawning and
// liveness-refresh stay local (reusing the same shared helpers as the
// JSON-backed runtime, from workflow-worker-spawn.ts) -- only the registry
// *record-keeping* moves to Rails. A separate WorkerReconcileJob on the
// Rails side is a redundant safety net for workers whose supervisor loop
// died without ticking again; it doesn't replace this local check.

const defaultFileSystem: WorkerSpawnFileSystem = {
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

type CreateWorkerRuntimeRailsArgs = {
  rootDir: string
  outputDir: string
  fileSystem?: WorkerSpawnFileSystem
  processAdapter: WorkerProcessAdapter
  workerDriver?: WorkerDriver
  railsOptions?: RailsApiRequestOptions
}

function resolvePath(baseDir: string, suffix: string): string {
  return `${baseDir.replace(/\/$/, '')}/${suffix}`
}

async function postStop(
  worker: WorkflowWorkerRecord,
  reason: string,
  railsOptions: RailsApiRequestOptions
): Promise<WorkflowWorkerRecord> {
  return railsPost<WorkflowWorkerRecord>(
    `/api/workers/${encodeURIComponent(worker.workerId)}/stop`,
    { reason },
    railsOptions
  )
}

export function createWorkflowWorkerRuntimeRails(args: CreateWorkerRuntimeRailsArgs): WorkflowWorkerRuntime {
  const fileSystem = args.fileSystem ?? defaultFileSystem
  const processAdapter = args.processAdapter
  const workersDir = resolvePath(args.outputDir, 'workers')
  const workerDriver: WorkerDriver = args.workerDriver ?? 'codex'
  const railsOptions = args.railsOptions ?? {}

  const ensureDir = () => {
    fs.mkdirSync(args.outputDir, { recursive: true })
    fs.mkdirSync(workersDir, { recursive: true })
  }

  // Mirrors workflow-worker-runtime.ts's refreshWorkers(): a worker Rails
  // still shows as "running" may have actually exited since the last tick
  // (only the local process adapter can know this) -- flip it to stopped
  // locally in the returned list and PATCH Rails so the registry catches up.
  const refreshWorkers = async (workers: WorkflowWorkerRecord[]): Promise<WorkflowWorkerRecord[]> => {
    return Promise.all(
      workers.map(async (worker) => {
        if (worker.status !== 'running' || processAdapter.isAlive(worker.pid)) {
          return worker
        }

        const stopReason = describeWorkerExit(fileSystem, worker, processAdapter.getExitStatus?.(worker.pid) ?? null)
        appendWorkerLogLine(
          fileSystem,
          worker.logPath,
          formatWorkflowWorkerLifecycleLine({
            timestamp: new Date().toISOString(),
            event: 'stopped',
            workerId: worker.workerId,
            runId: worker.runId,
            role: worker.role,
            nickname: worker.nickname,
            pid: worker.pid,
            scope: worker.scope,
            reason: worker.reason,
            command: worker.command,
            status: 'stopped',
            stopReason,
          })
        )

        return postStop(worker, stopReason, railsOptions)
      })
    )
  }

  return {
    async spawnWorker(spawnArgs) {
      ensureDir()
      const worker = spawnWorkerProcess(
        { rootDir: args.rootDir, workersDir, workerDriver, fileSystem, processAdapter },
        spawnArgs
      )

      return railsPost<WorkflowWorkerRecord>('/api/workers', worker, railsOptions)
    },

    async listWorkers(listArgs = {}) {
      const workers = await railsGet<WorkflowWorkerRecord[]>(
        '/api/workers',
        { runId: listArgs.runId, activeOnly: listArgs.activeOnly },
        railsOptions
      )

      return refreshWorkers(workers)
    },

    async stopWorker(stopArgs) {
      const workers = await railsGet<WorkflowWorkerRecord[]>('/api/workers', undefined, railsOptions)
      const refreshed = await refreshWorkers(workers)
      const worker = refreshed.find((candidate) =>
        'workerId' in stopArgs ? candidate.workerId === stopArgs.workerId : candidate.nickname === stopArgs.nickname
      )

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

      const stoppedAt = new Date().toISOString()
      appendWorkerLogLine(
        fileSystem,
        worker.logPath,
        formatWorkflowWorkerLifecycleLine({
          timestamp: stoppedAt,
          event: 'stopped',
          workerId: worker.workerId,
          runId: worker.runId,
          role: worker.role,
          nickname: worker.nickname,
          pid: worker.pid,
          scope: worker.scope,
          reason: worker.reason,
          command: worker.command,
          status: 'stopped',
          stopReason: stopArgs.reason,
        })
      )

      return postStop(worker, stopArgs.reason, railsOptions)
    },
  }
}
