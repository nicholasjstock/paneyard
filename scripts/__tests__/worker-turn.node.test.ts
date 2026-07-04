// @vitest-environment node

import { describe, expect, test } from 'vitest'

import { runWorkerTurn } from '../worker-turn'
import type { WorkflowManagedRole } from '../workflow-worker-runtime'

describe('worker turn', () => {
  test('always spawns a planner with the result and the current followingSteps as context', () => {
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
      workerRuntime,
      previousState: {
        runId: 'run-6',
        phase: 'planning',
        tickCount: 2,
        lastPlanSummary: 'previous summary',
        pendingSpawnKeys: [],
        followingSteps: [{ owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the fix.' }],
        lastStallFinding: null,
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(spawnCalls).toHaveLength(1)
    expect(spawnCalls[0]?.role).toBe('planner')
    expect(spawnCalls[0]?.prompt).toContain('The frontend coverage-request button does not respond to clicks.')
    expect(spawnCalls[0]?.prompt).toContain('verifier-report.md')
    expect(result.plannerWorker).not.toBeNull()
    expect(result.plannerWorker?.role).toBe('planner')
    // worker_turn never decides anything itself — it just carries the
    // previous followingSteps forward for the spawned planner to consume.
    expect(result.nextState.followingSteps).toEqual([
      { owner: 'worker', artifact: 'verifier-report.md', successCheck: 'Confirms the fix.' },
    ])
  })

  test('plannerWorker is null when no workerRuntime is provided', () => {
    const result = runWorkerTurn({
      runId: 'run-7',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    })

    expect(result.plannerWorker).toBeNull()
  })

  test('does not spawn a second planner worker when one is already active for the run', () => {
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
      workerRuntime,
    })

    expect(spawnCalls).toHaveLength(0)
    expect(result.plannerWorker).toBeNull()
  })

  test('still spawns a planner worker when only non-planner workers are active', () => {
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
      workerRuntime,
    })

    expect(spawnCalls).toHaveLength(1)
    expect(result.plannerWorker).not.toBeNull()
  })

  test('nextState defaults phase/tickCount and followingSteps when no previousState is given', () => {
    const result = runWorkerTurn({
      runId: 'run-11',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    })

    expect(result.nextState.phase).toBe('starting')
    expect(result.nextState.tickCount).toBe(0)
    expect(result.nextState.followingSteps).toEqual([])
  })

  test('nextState carries orchestrator/planner-owned fields forward untouched', () => {
    const result = runWorkerTurn({
      runId: 'run-12',
      role: 'worker',
      nickname: 'worker',
      scope: 'verifier-report.md',
      result: 'irrelevant text',
      task: 'irrelevant',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      previousState: {
        runId: 'run-12',
        phase: 'stalled',
        tickCount: 5,
        lastPlanSummary: 'old summary',
        pendingSpawnKeys: ['a-key'],
        followingSteps: [{ owner: 'worker', artifact: 'stale.md', successCheck: 'stale' }],
        lastStallFinding: 'old finding',
        lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      },
    })

    expect(result.nextState.phase).toBe('stalled')
    expect(result.nextState.tickCount).toBe(5)
    expect(result.nextState.lastStallFinding).toBe('old finding')
    expect(result.nextState.lastPlanSummary).toBe('old summary')
    expect(result.nextState.pendingSpawnKeys).toEqual(['a-key'])
    expect(result.nextState.followingSteps).toEqual([{ owner: 'worker', artifact: 'stale.md', successCheck: 'stale' }])
  })
})
