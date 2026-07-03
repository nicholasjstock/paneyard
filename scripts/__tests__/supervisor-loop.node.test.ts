// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'
import { createNodeWorkerProcessAdapter } from '../workflow-worker-runtime-node'
import { resolveOrchestratorLauncher, spawnRequestedWorkers } from '../supervisor-loop'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

function withEnv<T>(entries: Record<string, string | undefined>, callback: () => Promise<T>): Promise<T> {
  const previous = new Map<string, string | undefined>()

  for (const [key, value] of Object.entries(entries)) {
    previous.set(key, process.env[key])
    if (typeof value === 'undefined') {
      delete process.env[key]
    } else {
      process.env[key] = value
    }
  }

  return callback().finally(() => {
    for (const [key, value] of previous.entries()) {
      if (typeof value === 'undefined') {
        delete process.env[key]
      } else {
        process.env[key] = value
      }
    }
  })
}

async function waitForFile(filePath: string, timeoutMs = 5000): Promise<void> {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (fs.existsSync(filePath)) {
      return
    }

    await new Promise((resolve) => setTimeout(resolve, 50))
  }

  throw new Error(`Timed out waiting for file: ${filePath}`)
}

describe('supervisor loop worker spawning', () => {
  test('dedupes open planner requests by run, role, and scope before spawning', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supervisor-loop-'))
    tempDirs.push(tempDir)
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const spawned: Array<{ role: string; nickname: string; scope: string; reason: string; prompt: string }> = []

    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'recorder-report.md',
      text: 'Run the recorder.',
      requestedRole: 'demo_recorder',
      priority: 'blocking',
      tags: ['demo_recorder', 'recorder-report.md', 'planner-job'],
    })
    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'recorder-report.md',
      text: 'Run the recorder again.',
      requestedRole: 'demo_recorder',
      priority: 'blocking',
      tags: ['demo_recorder', 'recorder-report.md', 'planner-job'],
    })
    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'verifier-report.md',
      text: 'Run the verifier.',
      requestedRole: 'demo_verifier',
      priority: 'blocking',
      tags: ['demo_verifier', 'verifier-report.md', 'planner-job'],
    })

    const spawnedWorkers = spawnRequestedWorkers({
      runId: 'demo-20260702-130619',
      workerRuntime: {
        listWorkers() {
          return []
        },
        spawnWorker(args) {
          spawned.push(args)
          return {
            workerId: `worker-${spawned.length}`,
            runId: args.runId,
            role: args.role,
            nickname: args.nickname,
            reason: args.reason,
            scope: args.scope,
            status: 'running',
            pid: 43000 + spawned.length,
            promptPath: `/tmp/${args.nickname}.prompt.txt`,
            logPath: `/tmp/${args.nickname}.log`,
            lastMessagePath: `/tmp/${args.nickname}.last-message.txt`,
            envPath: `/tmp/${args.nickname}.env.json`,
            command: 'codex',
            args: ['exec', '-'],
            startedAt: '2026-07-02T10:05:00.000Z',
            stoppedAt: null,
            stopReason: null,
          }
        },
      },
      bus,
    })

    expect(spawnedWorkers.map((worker) => worker.role)).toEqual(['demo_recorder', 'demo_verifier'])
    expect(spawned.map((call) => call.role)).toEqual(['demo_recorder', 'demo_verifier'])
    expect(spawned.map((call) => call.nickname)).toEqual(['demo-recorder', 'demo-verifier'])
  })
})

describe('supervisor loop worker spawning integration', () => {
  test('an open spawn request results in a real spawned process and a bus worker_spawned event', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supervisor-loop-integration-'))
    tempDirs.push(tempDir)
    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const binDir = path.join(tempDir, 'bin')
    const promptCapturePath = path.join(tempDir, 'child-prompt.txt')
    fs.mkdirSync(binDir, { recursive: true })
    fs.writeFileSync(
      path.join(binDir, 'codex'),
      `#!/usr/bin/env node
const fs = require('fs')
fs.writeFileSync(process.env.FAKE_CODEX_PROMPT_CAPTURE_PATH, fs.readFileSync(0, 'utf8'))
setInterval(() => {}, 1000)
`,
      { mode: 0o755 }
    )

    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runId = 'demo-20260703-140000'

    const request = bus.appendSpawnRequest({
      runId,
      askedBy: 'orchestrator',
      scope: 'recorder-report.md',
      text: 'Run the recorder.',
      requestedRole: 'demo_recorder',
      priority: 'blocking',
      tags: ['demo_recorder', 'recorder-report.md', 'planner-job'],
    })

    const workerRuntime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: createNodeWorkerProcessAdapter(),
    })

    await withEnv(
      {
        PATH: `${binDir}:${process.env.PATH ?? ''}`,
        FAKE_CODEX_PROMPT_CAPTURE_PATH: promptCapturePath,
      },
      async () => {
        const spawnedWorkers = spawnRequestedWorkers({ runId, workerRuntime, bus })

        expect(spawnedWorkers.map((worker) => worker.role)).toEqual(['demo_recorder'])

        await waitForFile(promptCapturePath)

        const activeWorkers = workerRuntime.listWorkers({ runId, activeOnly: true })
        expect(activeWorkers).toHaveLength(1)
        expect(activeWorkers[0]).toMatchObject({
          role: 'demo_recorder',
          nickname: 'demo-recorder',
          status: 'running',
        })
        expect(typeof activeWorkers[0].pid).toBe('number')

        const spawnedEvents = bus
          .listRecentEvents()
          .filter(
            (event) =>
              event.type === 'worker.spawned' &&
              (event.payload as { runId?: string }).runId === runId
          )
        expect(spawnedEvents).toHaveLength(1)
        expect(spawnedEvents[0].payload).toMatchObject({ role: 'demo_recorder', nickname: 'demo-recorder' })

        const openRequests = bus.listOpenSpawnRequests()
        expect(openRequests.map((entry) => entry.requestId)).not.toContain(request.requestId)

        // Once the request is fulfilled, a second tick against the same bus
        // state must not spawn a duplicate worker.
        const secondTickSpawns = spawnRequestedWorkers({ runId, workerRuntime, bus })
        expect(secondTickSpawns).toHaveLength(0)
        expect(workerRuntime.listWorkers({ runId, activeOnly: true })).toHaveLength(1)

        await workerRuntime.stopWorker({
          workerId: activeWorkers[0].workerId,
          reason: 'Clean up test worker.',
        })
      }
    )
  })
})

describe('resolveOrchestratorLauncher', () => {
  test('defaults to bin/orchestrator_launcher under the given root', () => {
    expect(resolveOrchestratorLauncher({}, '/repo')).toBe('/repo/bin/orchestrator_launcher')
  })

  test('honors an ORCHESTRATOR_LAUNCHER override for the claude-driven orchestrator', () => {
    expect(
      resolveOrchestratorLauncher({ ORCHESTRATOR_LAUNCHER: '/repo/bin/orchestrator_launcher_claude' }, '/repo')
    ).toBe('/repo/bin/orchestrator_launcher_claude')
  })
})
