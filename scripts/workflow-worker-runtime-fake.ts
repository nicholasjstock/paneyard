import * as fs from 'fs'
import * as path from 'path'

import type { WorkerProcessAdapter } from './workflow-worker-runtime'

type FakeSpawnCallRecord = {
  pid: number
  command: string
  args: string[]
  cwd: string
  at: string
}

function ensureParentDir(filePath: string): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
}

function appendCallRecord(logFilePath: string, record: FakeSpawnCallRecord): void {
  ensureParentDir(logFilePath)
  fs.appendFileSync(logFilePath, `${JSON.stringify(record)}\n`)
}

export function createFakeWorkerProcessAdapter(logFilePath: string): WorkerProcessAdapter {
  let nextPid = 900000
  const alivePids = new Set<number>()

  return {
    spawn(command, args, options) {
      nextPid += 1
      const pid = nextPid
      alivePids.add(pid)

      appendCallRecord(logFilePath, {
        pid,
        command,
        args,
        cwd: options.cwd,
        at: new Date().toISOString(),
      })

      return {
        pid,
        stdin: {
          write() {},
          end() {},
        },
        unref() {},
      }
    },
    isAlive(pid) {
      return alivePids.has(pid)
    },
    kill(pid) {
      alivePids.delete(pid)
    },
  }
}
