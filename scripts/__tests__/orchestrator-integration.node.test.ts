// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createFakeWorkflowBus, createFakeWorkflowWorkerRuntime } from './helpers/fake-workflow-bus'
import { runOrchestratorTurn } from '../orchestrator-turn'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('orchestrator integration', () => {
  test('publishes the opening run status and stays idle for a full turn without spawning workers directly', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-integration-'))
    tempDirs.push(tempDir)
    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const bus = createFakeWorkflowBus()
    const runId = 'demo-xvfb-20260701-200813'
    let runtimeSpawnCount = 0

    const runtime = createFakeWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: {
        spawn() {
          const pid = 48000 + runtimeSpawnCount
          runtimeSpawnCount += 1

          return {
            pid,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive() {
          return true
        },
        kill() {},
      },
    })

    const result = await runOrchestratorTurn({
      runId,
      task: 'Resume the production demo orchestration. Finish the 28 step process and produce the next bounded handoff shape for recorder and verifier workers.',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })

    expect(result.plan).toBeNull()
    expect(result.jobs).toEqual([])
    expect(await bus.listOpenSpawnRequests()).toHaveLength(0)
    expect(await runtime.listWorkers({ runId, activeOnly: true })).toEqual([])

    const recentEvents = await bus.listRecentEvents(5)
    const recentEventTypes = recentEvents.map((event) => event.type)
    expect(recentEventTypes).toEqual(['run.status'])

    const [statusEvent] = recentEvents
    expect(statusEvent?.type).toBe('run.status')
    expect(statusEvent?.payload).toMatchObject({
      runId,
      phase: 'starting',
      owner: 'orchestrator',
    })
  })
})
