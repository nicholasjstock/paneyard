import * as fs from 'fs'
import { spawn } from 'child_process'

import type { WorkerExitStatus, WorkerProcessAdapter } from './workflow-worker-runtime'

export function createNodeWorkerProcessAdapter(): WorkerProcessAdapter {
  const exitStatuses = new Map<number, WorkerExitStatus>()

  return {
    spawn(command, args, options) {
      const outFd = fs.openSync(options.logPath ?? '/dev/null', 'a')

      try {
        const child = spawn(command, args, {
          cwd: options.cwd,
          detached: options.detached ?? false,
          env: options.env,
          stdio: ['pipe', outFd, outFd],
        })

        if (typeof child.pid === 'number') {
          const pid = child.pid
          child.on('exit', (code, signal) => {
            exitStatuses.set(pid, { code, signal })
          })
        }

        return {
          pid: child.pid ?? -1,
          stdin: child.stdin
            ? {
                write(chunk) {
                  child.stdin?.write(chunk)
                },
                end(chunk) {
                  child.stdin?.end(chunk)
                },
              }
            : undefined,
          unref() {
            child.unref()
          },
        }
      } finally {
        fs.closeSync(outFd)
      }
    },
    isAlive(pid) {
      try {
        process.kill(pid, 0)
        return true
      } catch {
        return false
      }
    },
    kill(pid, signal) {
      process.kill(pid, signal)
    },
    getExitStatus(pid) {
      return exitStatuses.get(pid) ?? null
    },
  }
}
