// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'
import { createNodeWorkerProcessAdapter } from '../workflow-worker-runtime-node'
import { resolveLatestPersistedRun, spawnRequestedWorkers } from '../supervisor-loop'

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
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'recorder-report.md', 'planner-job'],
    })
    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'recorder-report.md',
      text: 'Run the recorder again.',
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'recorder-report.md', 'planner-job'],
    })
    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'verifier-report.md',
      text: 'Run the verifier.',
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'verifier-report.md', 'planner-job'],
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
            workerId: args.workerId ?? `worker-${spawned.length}`,
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

    expect(spawnedWorkers.map((worker) => worker.role)).toEqual(['worker', 'worker'])
    expect(spawned.map((call) => call.role)).toEqual(['worker', 'worker'])
    expect(spawned.map((call) => call.nickname)).toEqual(['worker', 'worker-1'])
  })

  test('dismisses an open request superseded by an already-active worker claiming the same role/scope, and allows a fresh ask once that claim expires', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supervisor-loop-claim-'))
    tempDirs.push(tempDir)
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runId = 'demo-claim-run'
    const spawned: Array<{ role: string; scope: string }> = []
    const activePlannerWorker = {
      workerId: 'planner-1',
      runId,
      role: 'planner' as const,
      nickname: 'planner',
      reason: 'Recover the stalled worker.',
      scope: 'workflow-plan.md',
      status: 'running' as const,
      pid: 51000,
      promptPath: '/tmp/planner.prompt.txt',
      logPath: '/tmp/planner.log',
      lastMessagePath: '/tmp/planner.last-message.txt',
      envPath: '/tmp/planner.env.json',
      command: 'codex',
      args: ['exec', '-'],
      startedAt: '2026-07-02T10:05:00.000Z',
      stoppedAt: null,
      stopReason: null,
    }
    let plannerStillActive = true

    const workerRuntime = {
      listWorkers(listArgs?: { runId?: string; activeOnly?: boolean }) {
        if (listArgs?.activeOnly && !plannerStillActive) {
          return []
        }
        return [activePlannerWorker]
      },
      spawnWorker(spawnArgs: { role: string; scope: string; workerId?: string }) {
        spawned.push({ role: spawnArgs.role, scope: spawnArgs.scope })
        return {
          ...activePlannerWorker,
          workerId: spawnArgs.workerId ?? `planner-${spawned.length + 1}`,
          nickname: `planner-${spawned.length + 1}`,
        }
      },
    }

    // A second recovery ask arrives (e.g. a re-triggered stall tick) while
    // the first recovery planner is still actively running for the exact
    // same (role, scope).
    const duplicateRequest = bus.appendSpawnRequest({
      runId,
      askedBy: 'planner',
      scope: 'workflow-plan.md',
      text: 'Inspect this stalled-worker context (idleForMs=999999) and recover.',
      requestedRole: 'planner',
      priority: 'blocking',
      tags: ['planner', 'workflow-plan.md', 'planner-job'],
    })

    const firstPassSpawned = spawnRequestedWorkers({ runId, workerRuntime, bus })

    expect(firstPassSpawned).toEqual([])
    expect(spawned).toEqual([])
    const dismissed = bus.listSpawnRequests().find((request) => request.requestId === duplicateRequest.requestId)
    expect(dismissed?.status).toBe('dismissed')
    expect(dismissed?.dismissalNote).toContain('planner/workflow-plan.md')

    // The original planner claim finishes. A brand new ask for the same
    // (role, scope) should now be free to spawn — the claim expired with
    // the worker, it wasn't a permanent block.
    plannerStillActive = false
    const freshRequest = bus.appendSpawnRequest({
      runId,
      askedBy: 'planner',
      scope: 'workflow-plan.md',
      text: 'Inspect this stalled-worker context (idleForMs=1500000) and recover.',
      requestedRole: 'planner',
      priority: 'blocking',
      tags: ['planner', 'workflow-plan.md', 'planner-job'],
    })

    const secondPassSpawned = spawnRequestedWorkers({ runId, workerRuntime, bus })

    expect(secondPassSpawned).toHaveLength(1)
    expect(spawned).toEqual([{ role: 'planner', scope: 'workflow-plan.md' }])
    const fulfilled = bus.listSpawnRequests().find((request) => request.requestId === freshRequest.requestId)
    expect(fulfilled?.status).toBe('fulfilled')
  })

  test('rolls back the claim when the worker actually fails to spawn, instead of leaving it fulfilled forever', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supervisor-loop-spawn-failure-'))
    tempDirs.push(tempDir)
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runId = 'demo-spawn-failure-run'

    const workerRuntime = {
      listWorkers() {
        return []
      },
      spawnWorker(): never {
        throw new Error('codex binary not found in PATH')
      },
    }

    const request = bus.appendSpawnRequest({
      runId,
      askedBy: 'planner',
      scope: 'recorder-report.md',
      text: 'Run the recorder.',
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'recorder-report.md', 'planner-job'],
    })

    expect(() => spawnRequestedWorkers({ runId, workerRuntime, bus })).toThrow('codex binary not found in PATH')

    const afterFailure = bus.listSpawnRequests().find((entry) => entry.requestId === request.requestId)
    expect(afterFailure?.status).toBe('dismissed')
    expect(afterFailure?.dismissalNote).toContain('failed to spawn')
    expect(afterFailure?.dismissalNote).toContain('codex binary not found in PATH')
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
      requestedRole: 'worker',
      priority: 'blocking',
      tags: ['worker', 'recorder-report.md', 'planner-job'],
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

        expect(spawnedWorkers.map((worker) => worker.role)).toEqual(['worker'])

        await waitForFile(promptCapturePath)

        const activeWorkers = workerRuntime.listWorkers({ runId, activeOnly: true })
        expect(activeWorkers).toHaveLength(1)
        expect(activeWorkers[0]).toMatchObject({
          role: 'worker',
          nickname: 'worker',
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
        expect(spawnedEvents[0].payload).toMatchObject({ role: 'worker', nickname: 'worker' })

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

describe('resolveLatestPersistedRun', () => {
  test('returns the latest non-history orchestrator state when the bus has no active run', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supervisor-loop-state-'))
    tempDirs.push(tempDir)
    const stateDir = path.join(tempDir, 'orchestrator-state')
    fs.mkdirSync(stateDir, { recursive: true })

    fs.writeFileSync(
      path.join(stateDir, 'demo-20260702-130619.json'),
      `${JSON.stringify({
        runId: 'demo-20260702-130619',
        tickCount: 2,
        lastPlanSummary: 'Older summary.',
        lastUpdatedAt: '2026-07-02T13:06:19.000Z',
      })}\n`
    )
    fs.writeFileSync(path.join(stateDir, 'demo-20260702-130620.history.json'), '[]\n')
    fs.writeFileSync(
      path.join(stateDir, 'demo-20260702-130620.json'),
      `${JSON.stringify({
        runId: 'demo-20260702-130620',
        tickCount: 3,
        lastPlanSummary: 'Latest summary.',
        lastUpdatedAt: '2026-07-02T13:06:20.000Z',
      })}\n`
    )

    expect(resolveLatestPersistedRun(stateDir)).toEqual({
      runId: 'demo-20260702-130620',
      summary: 'Latest summary.',
    })
  })
})
