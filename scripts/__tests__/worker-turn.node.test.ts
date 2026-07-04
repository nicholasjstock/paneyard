// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { runWorkerTurn } from '../worker-turn'
import type { WorkflowManagedRole } from '../workflow-worker-runtime'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

function makeBus() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'worker-turn-'))
  tempDirs.push(tempDir)
  return createWorkflowBus({ storagePath: path.join(tempDir, 'workflow-bus.json') })
}

describe('worker turn', () => {
  test('routes a frontend-flavored result to a scoped front/** fix', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-1',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'The frontend coverage-request button does not respond to clicks.',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.some((step) => step.successCheck.includes('front/**'))).toBe(true)
    expect(result.jobs.map((job) => job.step.owner)).toContain('worker')
    expect(bus.listOpenSpawnRequests().some((request) => request.requestedRole === 'worker')).toBe(true)
  })

  test('routes a backend-flavored result to a scoped back/** fix', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-2',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'The backend API returns a 500 error on shift creation.',
      task: 'Validate the admin flow',
      scenario: 'admin',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.some((step) => step.successCheck.includes('back/**'))).toBe(true)
  })

  test('routes an infrastructure-flavored result to a scoped infrastructure fix', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-3',
      role: 'worker',
      nickname: 'worker',
      scope: 'recorder-report.md',
      result: 'Docker Playwright version mismatch prevented recording from starting.',
      task: 'Record the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.some((step) => step.successCheck.includes('infrastructure'))).toBe(true)
  })

  test('publishes bus jobs idempotently across repeated calls for the same run', () => {
    const bus = makeBus()
    const args = {
      runId: 'run-4',
      role: 'worker' as const,
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'The frontend coverage-request button does not respond to clicks.',
      task: 'Validate the phone flow',
      scenario: 'phone' as const,
      frontendUrl: 'http://localhost:5174',
      bus,
    }

    const first = runWorkerTurn(args)
    const second = runWorkerTurn(args)

    expect(second.jobs.map((job) => job.requestId)).toEqual(first.jobs.map((job) => job.requestId))
  })

  test('uses an injected planner function instead of the default keyword matcher', () => {
    const bus = makeBus()
    const fakePlan = {
      summary: 'fake summary',
      steps: [{ owner: 'worker' as const, artifact: 'fix-summary.md', successCheck: 'fake check' }],
    }

    const result = runWorkerTurn({
      runId: 'run-5',
      role: 'worker',
      nickname: 'worker',
      scope: 'fix-summary.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      planner: () => fakePlan,
    })

    expect(result.plan).toEqual(fakePlan)
    expect(result.jobs.map((job) => job.step.owner)).toEqual(['worker'])
  })

  test('spawns a real planner worker with the result as context when a workerRuntime is provided', () => {
    const bus = makeBus()
    const spawnCalls: Array<{ runId: string; role: WorkflowManagedRole; nickname: string; scope: string; prompt: string }> = []
    const workerRuntime = {
      spawnWorker: (args: {
        runId: string
        role: WorkflowManagedRole
        nickname: string
        reason: string
        scope: string
        prompt: string
      }) => {
        spawnCalls.push(args)
        return {
          workerId: 'planner-worker-1',
          runId: args.runId,
          role: args.role,
          nickname: args.nickname,
          reason: args.reason,
          scope: args.scope,
          status: 'running' as const,
          pid: 900001,
          promptPath: '/tmp/planner.prompt.txt',
          logPath: '/tmp/planner.log',
          lastMessagePath: '/tmp/planner.last-message.txt',
          envPath: '/tmp/planner.env.json',
          command: 'codex',
          args: [],
          startedAt: new Date().toISOString(),
          stoppedAt: null,
          stopReason: null,
        }
      },
    }

    const result = runWorkerTurn({
      runId: 'run-6',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'The frontend coverage-request button does not respond to clicks.',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      workerRuntime,
    })

    expect(spawnCalls).toHaveLength(1)
    expect(spawnCalls[0]?.role).toBe('planner')
    expect(spawnCalls[0]?.prompt).toContain('The frontend coverage-request button does not respond to clicks.')
    expect(result.plannerWorker).not.toBeNull()
    expect(result.plannerWorker?.role).toBe('planner')
  })

  test('plannerWorker is null when no workerRuntime is provided', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-7',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plannerWorker).toBeNull()
  })

  test('does not re-request an artifact whose earlier identical request was already fulfilled', () => {
    const bus = makeBus()
    const args = {
      runId: 'run-8',
      role: 'worker' as const,
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone' as const,
      frontendUrl: 'http://localhost:5174',
      bus,
    }

    const first = runWorkerTurn(args)
    for (const job of first.jobs) {
      bus.fulfillSpawnRequest({ requestId: job.requestId, fulfilledBy: 'test', fulfillmentNote: 'test fulfillment' })
    }

    const second = runWorkerTurn(args)

    expect(second.jobs.map((job) => job.requestId)).toEqual(first.jobs.map((job) => job.requestId))
  })

  test('does not spawn a second planner worker when one is already active for the run', () => {
    const bus = makeBus()
    const spawnCalls: Array<{ role: WorkflowManagedRole }> = []
    const workerRuntime = {
      spawnWorker: (spawnArgs: { runId: string; role: WorkflowManagedRole; nickname: string; reason: string; scope: string; prompt: string }) => {
        spawnCalls.push(spawnArgs)
        return {
          workerId: 'w-1',
          runId: spawnArgs.runId,
          role: spawnArgs.role,
          nickname: spawnArgs.nickname,
          reason: spawnArgs.reason,
          scope: spawnArgs.scope,
          status: 'running' as const,
          pid: 1,
          promptPath: '/tmp/x.prompt.txt',
          logPath: '/tmp/x.log',
          lastMessagePath: '/tmp/x.last-message.txt',
          envPath: '/tmp/x.env.json',
          command: 'codex',
          args: [],
          startedAt: new Date().toISOString(),
          stoppedAt: null,
          stopReason: null,
        }
      },
      listWorkers: () => [
        {
          workerId: 'existing-planner',
          runId: 'run-9',
          role: 'planner' as const,
          nickname: 'planner-existing',
          reason: 'already reasoning',
          scope: 'verifier-report.md',
          status: 'running' as const,
          pid: 2,
          promptPath: '/tmp/p.prompt.txt',
          logPath: '/tmp/p.log',
          lastMessagePath: '/tmp/p.last-message.txt',
          envPath: '/tmp/p.env.json',
          command: 'codex',
          args: [],
          startedAt: new Date().toISOString(),
          stoppedAt: null,
          stopReason: null,
        },
      ],
    }

    const result = runWorkerTurn({
      runId: 'run-9',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      workerRuntime,
    })

    expect(spawnCalls).toHaveLength(0)
    expect(result.plannerWorker).toBeNull()
  })

  test('still spawns a planner worker when only non-planner workers are active', () => {
    const bus = makeBus()
    const spawnCalls: Array<{ role: WorkflowManagedRole }> = []
    const workerRuntime = {
      spawnWorker: (spawnArgs: { runId: string; role: WorkflowManagedRole; nickname: string; reason: string; scope: string; prompt: string }) => {
        spawnCalls.push(spawnArgs)
        return {
          workerId: 'w-2',
          runId: spawnArgs.runId,
          role: spawnArgs.role,
          nickname: spawnArgs.nickname,
          reason: spawnArgs.reason,
          scope: spawnArgs.scope,
          status: 'running' as const,
          pid: 3,
          promptPath: '/tmp/y.prompt.txt',
          logPath: '/tmp/y.log',
          lastMessagePath: '/tmp/y.last-message.txt',
          envPath: '/tmp/y.env.json',
          command: 'codex',
          args: [],
          startedAt: new Date().toISOString(),
          stoppedAt: null,
          stopReason: null,
        }
      },
      listWorkers: () => [
        {
          workerId: 'existing-worker',
          runId: 'run-10',
          role: 'worker' as const,
          nickname: 'worker-existing',
          reason: 'still recording',
          scope: 'recorder-report.md',
          status: 'running' as const,
          pid: 4,
          promptPath: '/tmp/w.prompt.txt',
          logPath: '/tmp/w.log',
          lastMessagePath: '/tmp/w.last-message.txt',
          envPath: '/tmp/w.env.json',
          command: 'codex',
          args: [],
          startedAt: new Date().toISOString(),
          stoppedAt: null,
          stopReason: null,
        },
      ],
    }

    const result = runWorkerTurn({
      runId: 'run-10',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      workerRuntime,
    })

    expect(spawnCalls).toHaveLength(1)
    expect(result.plannerWorker).not.toBeNull()
  })

  test('nextState defaults phase/tickCount and reflects the decided plan when no previousState is given', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-11',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.nextState.phase).toBe('starting')
    expect(result.nextState.tickCount).toBe(0)
    expect(result.nextState.recommendedNextSteps).toEqual(result.plan.steps)
  })

  test('nextState carries orchestrator-owned fields forward untouched and replaces recommendedNextSteps', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-12',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      previousState: {
        runId: 'run-12',
        phase: 'stalled',
        tickCount: 5,
        lastPlanSummary: 'old summary',
        pendingSpawnKeys: [],
        recommendedNextSteps: [{ owner: 'worker', artifact: 'stale.md', successCheck: 'stale' }],
        lastStallFinding: 'old finding',
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(result.nextState.phase).toBe('stalled')
    expect(result.nextState.tickCount).toBe(5)
    expect(result.nextState.lastStallFinding).toBe('old finding')
    expect(result.nextState.recommendedNextSteps).toEqual(result.plan.steps)
  })
})
