// @vitest-environment node

import { describe, expect, test } from 'vitest'

import { createFakeWorkflowBus } from './helpers/fake-workflow-bus'
import { runPlannerTurn } from '../planner-turn'

function makeBus() {
  return createFakeWorkflowBus()
}

describe('planner turn', () => {
  test('publishes a spawn request for nextStep and carries followingSteps into state', async () => {
    const bus = makeBus()

    const result = await runPlannerTurn({
      runId: 'run-1',
      summary: 'Frontend button unresponsive; route to a scoped fix, then re-verify.',
      nextStep: { owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Button responds to taps on the phone view.' },
      followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the button now responds.' }],
      bus,
    })

    expect(result.jobs.map((job) => job.step.owner)).toEqual(['worker'])
    expect(result.jobs.map((job) => job.step.artifact)).toEqual(['fix-summary.md'])
    expect(result.nextState.followingSteps.map((step) => step.artifact)).toEqual(['verifier-report.md'])

    const openRequests = await bus.listOpenSpawnRequests()
    expect(openRequests.map((request) => request.requestedRole)).toEqual(['worker'])
    expect(openRequests[0]?.askedBy).toBe('planner')
    expect(openRequests[0]?.status).toBe('open')
  })

  test('a nextStep decision publishes exactly one bus entry', async () => {
    const bus = makeBus()

    const result = await runPlannerTurn({
      runId: 'run-2',
      summary: 'Infra fix needed.',
      nextStep: { owner: 'worker', artifact: 'fix-summary.md', successCheck: 'Docker image matches Playwright version.' },
      followingSteps: [],
      bus,
    })

    expect(result.jobs).toHaveLength(1)
    expect(await bus.listOpenSpawnRequests()).toHaveLength(1)
  })

  test('a null nextStep publishes nothing', async () => {
    const bus = makeBus()

    const result = await runPlannerTurn({
      runId: 'run-3',
      summary: 'No further action needed.',
      nextStep: null,
      followingSteps: [],
      bus,
    })

    expect(result.jobs).toEqual([])
    expect(await bus.listOpenSpawnRequests()).toEqual([])
    expect(result.nextState.followingSteps).toEqual([])
  })

  test('is idempotent across repeated calls for the same run and nextStep', async () => {
    const bus = makeBus()
    const args = {
      runId: 'run-4',
      summary: 'Frontend button unresponsive; route to a scoped fix.',
      nextStep: { owner: 'worker' as const, artifact: 'fix-summary.md', successCheck: 'Button responds to taps.' },
      followingSteps: [],
      bus,
    }

    const first = await runPlannerTurn(args)
    const second = await runPlannerTurn(args)

    expect(second.jobs.map((job) => job.requestId)).toEqual(first.jobs.map((job) => job.requestId))
    expect(await bus.listOpenSpawnRequests()).toHaveLength(1)
  })

  test('carries pendingSpawnKeys and tickCount forward from previousState', async () => {
    const bus = makeBus()

    const result = await runPlannerTurn({
      runId: 'run-5',
      summary: 'Recover the stalled worker.',
      nextStep: { owner: 'planner', artifact: 'workflow-plan.md', successCheck: 'Decide the recovery step.' },
      followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the flow.' }],
      bus,
      previousState: {
        runId: 'run-5',
        phase: 'stalled',
        tickCount: 3,
        lastPlanSummary: 'old summary',
        pendingSpawnKeys: ['existing-key'],
        followingSteps: [],
        lastStallFinding: 'old finding',
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(result.nextState.tickCount).toBe(4)
    expect(result.nextState.pendingSpawnKeys).toContain('existing-key')
    expect(result.nextState.phase).toBe('planning')
    expect(result.nextState.lastStallFinding).toBe('old finding')
    expect(result.nextState.followingSteps.map((step) => step.artifact)).toEqual(['verifier-report.md'])
  })
})
