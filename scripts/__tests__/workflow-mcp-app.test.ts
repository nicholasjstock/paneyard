// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'
import { collectWorkflowServerState } from '../workflow-state'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('workflow MCP app state snapshot', () => {
  test('captures bus, worker, and event state for the web UI', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-mcp-state-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: {
        spawn() {
          return {
            pid: 63001,
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

    bus.publishRunStatus({
      runId: 'demo-2026-07-02',
      phase: 'recording',
      owner: 'orchestrator',
      summary: 'Recording is live.',
    })
    bus.appendSpawnRequest({
      runId: 'demo-2026-07-02',
      askedBy: 'planner',
      scope: 'recorder-report.md',
      text: 'Re-run the recorder after the fix.',
      requestedRole: 'demo_recorder',
      priority: 'blocking',
    })
    runtime.spawnWorker({
      runId: 'demo-2026-07-02',
      role: 'demo_recorder',
      nickname: 'demo-recorder',
      reason: 'Recording the flow.',
      scope: 'recorder-report.md',
      prompt: 'Record the demo.',
    })
    bus.appendUserQuestion({
      runId: 'demo-2026-07-02',
      askedBy: 'planner',
      scope: 'environment choice',
      text: 'Should this continue against staging or production?',
      priority: 'blocking',
    })

    const state = collectWorkflowServerState({
      bus,
      workerRuntime: runtime,
    })

    expect(state.runStatuses).toHaveLength(1)
    expect(state.openSpawnRequests).toHaveLength(1)
    expect(state.openUserQuestions).toHaveLength(1)
    expect(state.workers).toHaveLength(1)
    expect(state.recentEvents.length).toBeGreaterThan(0)
    expect(state.workers[0]?.nickname).toBe('demo-recorder')
    expect(state.openSpawnRequests[0]?.requestedRole).toBe('demo_recorder')
    expect(state.openUserQuestions[0]?.askedBy).toBe('planner')
  })
})
