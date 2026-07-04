// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { runPlannerTurn } from '../planner-turn'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

function makeBus() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'planner-turn-'))
  tempDirs.push(tempDir)
  return createWorkflowBus({ storagePath: path.join(tempDir, 'workflow-bus.json') })
}

describe('planner turn', () => {
  test('publishes one spawn request per decided step', () => {
    const bus = makeBus()

    const result = runPlannerTurn({
      runId: 'run-1',
      summary: 'Frontend button unresponsive; route to a scoped fix, then re-verify.',
      steps: [
        { owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Button responds to taps on the phone view.' },
        { owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the button now responds.' },
      ],
      bus,
    })

    expect(result.jobs.map((job) => job.step.owner)).toEqual(['worker', 'worker'])

    const openRequests = bus.listOpenSpawnRequests()
    expect(openRequests.map((request) => request.requestedRole)).toEqual(['worker', 'worker'])
    for (const request of openRequests) {
      expect(request.askedBy).toBe('planner')
      expect(request.status).toBe('open')
    }
  })

  test('a single-step decision publishes exactly one bus entry', () => {
    const bus = makeBus()

    const result = runPlannerTurn({
      runId: 'run-2',
      summary: 'Infra fix needed.',
      steps: [{ owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Docker image matches Playwright version.' }],
      bus,
    })

    expect(result.jobs).toHaveLength(1)
    expect(bus.listOpenSpawnRequests()).toHaveLength(1)
  })

  test('an empty steps array publishes nothing', () => {
    const bus = makeBus()

    const result = runPlannerTurn({
      runId: 'run-3',
      summary: 'No further action needed.',
      steps: [],
      bus,
    })

    expect(result.jobs).toEqual([])
    expect(bus.listOpenSpawnRequests()).toEqual([])
  })

  test('is idempotent across repeated calls for the same run and steps', () => {
    const bus = makeBus()
    const args = {
      runId: 'run-4',
      summary: 'Frontend button unresponsive; route to a scoped fix.',
      steps: [{ owner: 'worker' as const, artifact: 'fix-summary.md', successCheck: 'Button responds to taps.' }],
      bus,
    }

    const first = runPlannerTurn(args)
    const second = runPlannerTurn(args)

    expect(second.jobs.map((job) => job.requestId)).toEqual(first.jobs.map((job) => job.requestId))
    expect(bus.listOpenSpawnRequests()).toHaveLength(1)
  })
})
