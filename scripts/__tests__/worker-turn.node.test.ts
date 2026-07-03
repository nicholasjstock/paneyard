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
  test('routes a frontend-flavored result to front_fixer', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-1',
      role: 'demo_verifier',
      nickname: 'demo-verifier',
      scope: 'verifier-report.md',
      result: 'The frontend coverage-request button does not respond to clicks.',
      task: 'Validate the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.map((step) => step.owner)).toContain('front_fixer')
    expect(result.jobs.map((job) => job.step.owner)).toContain('front_fixer')
    expect(bus.listOpenSpawnRequests().some((request) => request.requestedRole === 'front_fixer')).toBe(true)
  })

  test('routes a backend-flavored result to back_fixer', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-2',
      role: 'demo_verifier',
      nickname: 'demo-verifier',
      scope: 'verifier-report.md',
      result: 'The backend API returns a 500 error on shift creation.',
      task: 'Validate the admin flow',
      scenario: 'admin',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.map((step) => step.owner)).toContain('back_fixer')
  })

  test('routes an infrastructure-flavored result to infra_fixer', () => {
    const bus = makeBus()

    const result = runWorkerTurn({
      runId: 'run-3',
      role: 'demo_recorder',
      nickname: 'demo-recorder',
      scope: 'recorder-report.md',
      result: 'Docker Playwright version mismatch prevented recording from starting.',
      task: 'Record the phone flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plan.steps.map((step) => step.owner)).toContain('infra_fixer')
  })

  test('publishes bus jobs idempotently across repeated calls for the same run', () => {
    const bus = makeBus()
    const args = {
      runId: 'run-4',
      role: 'demo_verifier' as const,
      nickname: 'demo-verifier',
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
      steps: [{ owner: 'general_fixer' as const, artifact: 'fix-summary.md', successCheck: 'fake check' }],
    }

    const result = runWorkerTurn({
      runId: 'run-5',
      role: 'front_fixer',
      nickname: 'front-fixer',
      scope: 'fix-summary.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
      planner: () => fakePlan,
    })

    expect(result.plan).toEqual(fakePlan)
    expect(result.jobs.map((job) => job.step.owner)).toEqual(['general_fixer'])
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
      role: 'demo_verifier',
      nickname: 'demo-verifier',
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
      role: 'demo_verifier',
      nickname: 'demo-verifier',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      bus,
    })

    expect(result.plannerWorker).toBeNull()
  })
})
