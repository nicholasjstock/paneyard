// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'
import { runOrchestratorTurn } from '../orchestrator-turn'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('orchestrator integration', () => {
  test('publishes the opening run status and planner jobs for a full turn without spawning workers directly', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-integration-'))
    tempDirs.push(tempDir)
    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runId = 'demo-xvfb-20260701-200813'
    let runtimeSpawnCount = 0

    const runtime = createWorkflowWorkerRuntime({
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

    const result = runOrchestratorTurn({
      runId,
      task: 'Resume the production demo orchestration. Finish the 28 step process and produce the next bounded handoff shape for recorder and verifier workers.',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })

    expect(result.plan.summary).toContain('both')
    expect(result.plan.steps.map((step) => step.owner)).toEqual([
      'orchestrator',
      'demo_recorder',
      'demo_verifier',
    ])
    expect(result.jobs.map((job) => job.step.owner)).toEqual(['demo_recorder', 'demo_verifier'])
    expect(bus.listOpenSpawnRequests()).toHaveLength(2)
    expect(runtime.listWorkers({ runId, activeOnly: true })).toEqual([])

    const recentEvents = bus.listRecentEvents(5)
    const recentEventTypes = recentEvents.map((event) => event.type)
    expect(recentEventTypes).toEqual([
      'run.status',
      'spawn_request.created',
      'spawn_request.created',
    ])

    const [statusEvent, firstQuestionEvent, secondQuestionEvent] = recentEvents
    expect(statusEvent?.type).toBe('run.status')
    expect(statusEvent?.payload).toMatchObject({
      runId,
      phase: 'starting',
      owner: 'orchestrator',
    })
    expect(firstQuestionEvent?.type).toBe('spawn_request.created')
    expect(firstQuestionEvent?.payload).toMatchObject({
      requestedRole: 'demo_recorder',
      priority: 'blocking',
    })
    expect(secondQuestionEvent?.type).toBe('spawn_request.created')
    expect(secondQuestionEvent?.payload).toMatchObject({
      requestedRole: 'demo_verifier',
      priority: 'blocking',
    })
  })
})
