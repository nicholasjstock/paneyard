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

describe('orchestrator turn', () => {
  test('detects a stalled worker and publishes a planner recovery job', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const workersDir = path.join(outputDir, 'workers')
    fs.mkdirSync(workersDir, { recursive: true })

    const logPath = path.join(workersDir, 'worker.log')
    const lastMessagePath = path.join(workersDir, 'worker.last-message.txt')
    const promptPath = path.join(workersDir, 'worker.prompt.txt')
    const envPath = path.join(workersDir, 'worker.env.json')
    let nextPid = 42000
    const workerRecord = {
      workerId: 'worker-1',
      runId: 'demo-20260702-130619',
      role: 'worker' as const,
      nickname: 'worker',
      reason: 'Frontend recording stalled on cursor overlay.',
      scope: 'frontend video review',
      status: 'running' as const,
      pid: 41001,
      promptPath,
      logPath,
      lastMessagePath,
      envPath,
      command: 'codex',
      args: ['exec', '-'],
      startedAt: '2026-07-02T10:00:00.000Z',
      stoppedAt: null,
      stopReason: null,
    }

    fs.writeFileSync(
      logPath,
      [
        '[workflow] 2026-07-02T10:00:00.000Z worker:lifecycle: spawned worker {"pid":41001}',
        'worker is still waiting on a browser frame',
      ].join('\n')
    )
    fs.writeFileSync(lastMessagePath, 'Waiting on the browser frame to move.')
    fs.writeFileSync(promptPath, 'Fix the stalled frontend recorder path.')
    fs.writeFileSync(envPath, '{}')

    const staleAt = new Date('2026-07-02T10:00:00.000Z')
    fs.utimesSync(logPath, staleAt, staleAt)
    fs.utimesSync(lastMessagePath, staleAt, staleAt)
    fs.utimesSync(promptPath, staleAt, staleAt)

    const runtime = createFakeWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      initialWorkers: [workerRecord],
      processAdapter: {
        spawn() {
          const pid = nextPid++
          return {
            pid,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive(pid) {
          return pid === 41001
        },
        kill() {
          throw new Error('kill should not be called in this test')
        },
      },
    })
    const bus = createFakeWorkflowBus()
    const result = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })

    expect(result.stalledWorkers).toHaveLength(1)
    expect(result.nextState.phase).toBe('stalled')
    expect(result.nextState.lastStallFinding).toContain('Stalled worker worker')
    expect(result.nextState.lastStallFinding).toContain('frontend video review')
    expect(result.plan?.nextStep?.owner).toBe('planner')
    expect(result.jobs.map((job) => job.step.owner)).toEqual(['planner'])
    const openRequests = await bus.listOpenSpawnRequests()
    expect(openRequests.map((request) => request.requestedRole)).toContain('planner')
  })

  test('repeated ticks on the same stall do not pile up duplicate planner recovery requests', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const workersDir = path.join(outputDir, 'workers')
    fs.mkdirSync(workersDir, { recursive: true })

    const logPath = path.join(workersDir, 'worker.log')
    const lastMessagePath = path.join(workersDir, 'worker.last-message.txt')
    const promptPath = path.join(workersDir, 'worker.prompt.txt')
    const envPath = path.join(workersDir, 'worker.env.json')
    const workerRecord = {
      workerId: 'worker-1',
      runId: 'demo-20260702-130619',
      role: 'worker' as const,
      nickname: 'worker',
      reason: 'Frontend recording stalled on cursor overlay.',
      scope: 'frontend video review',
      status: 'running' as const,
      pid: 41001,
      promptPath,
      logPath,
      lastMessagePath,
      envPath,
      command: 'codex',
      args: ['exec', '-'],
      startedAt: '2026-07-02T10:00:00.000Z',
      stoppedAt: null,
      stopReason: null,
    }

    fs.writeFileSync(logPath, 'worker is still waiting on a browser frame')
    fs.writeFileSync(lastMessagePath, 'Waiting on the browser frame to move.')
    fs.writeFileSync(promptPath, 'Fix the stalled frontend recorder path.')
    fs.writeFileSync(envPath, '{}')

    const staleAt = new Date('2026-07-02T10:00:00.000Z')
    fs.utimesSync(logPath, staleAt, staleAt)
    fs.utimesSync(lastMessagePath, staleAt, staleAt)
    fs.utimesSync(promptPath, staleAt, staleAt)

    const runtime = createFakeWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      initialWorkers: [workerRecord],
      processAdapter: {
        spawn() {
          return {
            pid: 42000,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive(pid) {
          return pid === 41001
        },
        kill() {
          throw new Error('kill should not be called in this test')
        },
      },
    })
    const bus = createFakeWorkflowBus()

    // Two ticks on the exact same still-stalled worker, 5s apart — idleForMs
    // (baked into the recovery successCheck text) differs between the two,
    // but the underlying ask ("recover this stall") has not changed.
    await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })
    const secondTick = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:05.000Z'),
    })

    const allOpenRequests = await bus.listOpenSpawnRequests()
    const plannerRequests = allOpenRequests.filter((request) => request.requestedRole === 'planner')
    expect(plannerRequests).toHaveLength(1)
    expect(secondTick.jobs.map((job) => job.step.owner)).toEqual(['planner'])
    expect(secondTick.jobs[0]?.requestId).toBe(plannerRequests[0]?.requestId)
  })

  test('does not spawn planner workers during the orchestrator tick', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const workersDir = path.join(outputDir, 'workers')
    fs.mkdirSync(workersDir, { recursive: true })

    const bus = createFakeWorkflowBus()
    const runId = 'demo-20260702-130619'

    await bus.appendSpawnRequest({
      runId,
      askedBy: 'worker',
      scope: 'recorder-report.md',
      text: 'Review the recorder report and publish the next worker_request set.',
      context:
        'The recorder finished writing front/demo-output/agents-sdk/recorder-report.md. It was blocked by resetWorkflowState() timing out with TypeError: fetch failed and UND_ERR_HEADERS_TIMEOUT.',
      requestedRole: 'planner',
      priority: 'blocking',
      tags: ['planner', 'recorder-report.md', 'planner-job'],
    })

    const activeRecorder = {
      workerId: 'worker-recorder',
      runId,
      role: 'worker' as const,
      nickname: 'demo-recorder',
      reason: 'Recorder is already active.',
      scope: 'recorder-report.md',
      status: 'running' as const,
      pid: 41001,
      promptPath: path.join(workersDir, 'demo-recorder.prompt.txt'),
      logPath: path.join(workersDir, 'demo-recorder.log'),
      lastMessagePath: path.join(workersDir, 'demo-recorder.last-message.txt'),
      envPath: path.join(workersDir, 'demo-recorder.env.json'),
      command: 'codex',
      args: ['exec', '-'],
      startedAt: '2026-07-02T10:00:00.000Z',
      stoppedAt: null,
      stopReason: null,
    }
    const activeVerifier = {
      workerId: 'worker-verifier',
      runId,
      role: 'worker' as const,
      nickname: 'demo-verifier',
      reason: 'Verifier is already active.',
      scope: 'verifier-report.md',
      status: 'running' as const,
      pid: 41002,
      promptPath: path.join(workersDir, 'demo-verifier.prompt.txt'),
      logPath: path.join(workersDir, 'demo-verifier.log'),
      lastMessagePath: path.join(workersDir, 'demo-verifier.last-message.txt'),
      envPath: path.join(workersDir, 'demo-verifier.env.json'),
      command: 'codex',
      args: ['exec', '-'],
      startedAt: '2026-07-02T10:00:00.000Z',
      stoppedAt: null,
      stopReason: null,
    }

    const spawned: Array<{ role: string; nickname: string; scope: string; reason: string; prompt: string }> = []

    const result = await runOrchestratorTurn({
      runId,
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        async listWorkers() {
          return [activeRecorder, activeVerifier]
        },
        async spawnWorker(args) {
          spawned.push(args)
          return {
            workerId: `worker-${spawned.length}`,
            runId: args.runId,
            role: args.role,
            nickname: args.nickname,
            reason: args.reason,
            scope: args.scope,
            status: 'running',
            pid: 42000 + spawned.length,
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
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })

    expect(result.jobs).toEqual([])
    expect(result.nextState.phase).toBe('waiting_on_workers')
    expect(spawned).toEqual([])
    const recentEvents = await bus.listRecentEvents(10)
    expect(recentEvents.map((event) => event.type)).not.toContain('worker.spawned')
  })

  test('does not spawn missing workers for open planner jobs in the same turn', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()
    const spawned: Array<{ role: string; nickname: string; scope: string; reason: string; prompt: string }> = []

    const result = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        async listWorkers() {
          return []
        },
        async spawnWorker(args) {
          spawned.push(args)
          return {
            workerId: `worker-${spawned.length}`,
            runId: args.runId,
            role: args.role,
            nickname: args.nickname,
            reason: args.reason,
            scope: args.scope,
            status: 'running',
            pid: 41000 + spawned.length,
            promptPath: `/tmp/${args.nickname}.prompt.txt`,
            logPath: `/tmp/${args.nickname}.log`,
            lastMessagePath: `/tmp/${args.nickname}.last-message.txt`,
            envPath: `/tmp/${args.nickname}.env.json`,
            command: 'codex',
            args: ['exec', '-'],
            startedAt: '2026-07-02T10:00:00.000Z',
            stoppedAt: null,
            stopReason: null,
          }
        },
      },
      bus,
      fileSystem: fs,
    })

    expect(result.jobs).toEqual([])
    expect(result.nextState.phase).toBe('starting')
    expect(spawned).toEqual([])
    const recentEvents = await bus.listRecentEvents(5)
    expect(recentEvents.map((event) => event.type)).not.toContain('worker.spawned')
  })

  test('does not append duplicate open planner jobs for the same run, role, and scope', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()

    const workerRuntime = {
      async listWorkers() {
        return []
      },
      async spawnWorker(): Promise<never> {
        throw new Error('orchestrator turn should not spawn workers')
      },
    }

    await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
    })

    await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
    })

    const openRequests = await bus.listOpenSpawnRequests()
    expect(
      openRequests
        .map((request) => [request.runId, request.requestedRole, request.scope].join('|'))
        .sort()
    ).toEqual([])
  })

  test('detects a dead end (no workers, no open requests, not completed) and asks a planner to recover', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()

    const result = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        async listWorkers() {
          return []
        },
        async spawnWorker(): Promise<never> {
          throw new Error('orchestrator turn should not spawn workers')
        },
      },
      bus,
      fileSystem: fs,
      previousState: {
        runId: 'demo-20260702-130619',
        phase: 'waiting_on_workers',
        tickCount: 3,
        lastPlanSummary: 'Previous planner summary.',
        pendingSpawnKeys: [],
        followingSteps: [],
        lastStallFinding: null,
        lastUpdatedAt: '2026-07-02T10:00:00.000Z',
      },
    })

    // Progress was made before (phase advanced past 'starting'), then
    // everything went idle without ever being marked completed — that's a
    // dead end, not a legitimate finish, so the orchestrator asks a planner
    // to recover instead of silently doing nothing forever.
    expect(result.plan?.nextStep?.owner).toBe('planner')
    expect(result.jobs.map((job) => job.step.owner)).toEqual(['planner'])
    expect(result.nextState.runId).toBe('demo-20260702-130619')
    expect(result.nextState.tickCount).toBe(4)
    expect(result.nextState.phase).toBe('stalled')
    expect(result.nextState.lastStallFinding).toContain('no active workers and no open spawn requests')
    expect(result.nextState.followingSteps).toEqual([])
    expect(result.nextState.lastPlanSummary).toBe(result.plan?.summary)
    expect(result.nextState.pendingSpawnKeys).toEqual([
      JSON.stringify(['demo-20260702-130619', 'planner', 'workflow-plan.md']),
    ])
  })

  test('does not spawn another recovery planner while a blocking user question is already open for the run', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()

    // A prior recovery planner already escalated this exact dead end to the
    // user instead of retrying again — the orchestrator must not ignore that
    // and spawn yet another recovery planner to redundantly re-investigate
    // the same thing while it's still awaiting a human answer.
    await bus.appendUserQuestion({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'phone-demo-video',
      text: 'Both recorder attempts stalled identically — how should I proceed?',
      priority: 'blocking',
    })

    const result = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        async listWorkers() {
          return []
        },
        async spawnWorker(): Promise<never> {
          throw new Error('orchestrator turn should not spawn workers')
        },
      },
      bus,
      fileSystem: fs,
      previousState: {
        runId: 'demo-20260702-130619',
        phase: 'waiting_on_workers',
        tickCount: 3,
        lastPlanSummary: 'Previous planner summary.',
        pendingSpawnKeys: [],
        followingSteps: [],
        lastStallFinding: null,
        lastUpdatedAt: '2026-07-02T10:00:00.000Z',
      },
    })

    expect(result.plan).toBeNull()
    expect(result.jobs).toEqual([])
    expect(result.nextState.phase).toBe('blocked_on_user')
    expect(await bus.listOpenSpawnRequests()).toEqual([])
  })

  test('resumes recovery once the blocking question has been answered', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()

    const question = await bus.appendUserQuestion({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'phone-demo-video',
      text: 'Both recorder attempts stalled identically — how should I proceed?',
      priority: 'blocking',
    })

    const workerRuntime = {
      async listWorkers() {
        return []
      },
      async spawnWorker(): Promise<never> {
        throw new Error('orchestrator turn should not spawn workers')
      },
    }
    const previousState = {
      runId: 'demo-20260702-130619',
      phase: 'waiting_on_workers' as const,
      tickCount: 3,
      lastPlanSummary: 'Previous planner summary.',
      pendingSpawnKeys: [],
      followingSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: '2026-07-02T10:00:00.000Z',
    }

    // Still suppressed while the question is open.
    const suppressed = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
      previousState,
    })
    expect(suppressed.plan).toBeNull()
    expect(suppressed.nextState.phase).toBe('blocked_on_user')

    await bus.answerUserQuestion({
      questionId: question.questionId,
      answeredBy: 'user',
      answerText: 'Kill both stalled processes and retry once more.',
    })

    const resumed = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
      previousState: suppressed.nextState,
    })

    expect(resumed.plan?.nextStep?.owner).toBe('planner')
    expect(resumed.jobs.map((job) => job.step.owner)).toEqual(['planner'])
    expect(resumed.nextState.phase).toBe('stalled')
  })

  test('does not treat a legitimately completed run as a dead end', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const bus = createFakeWorkflowBus()

    const result = await runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        async listWorkers() {
          return []
        },
        async spawnWorker(): Promise<never> {
          throw new Error('orchestrator turn should not spawn workers')
        },
      },
      bus,
      fileSystem: fs,
      previousState: {
        runId: 'demo-20260702-130619',
        phase: 'completed',
        tickCount: 5,
        lastPlanSummary: 'The run finished successfully.',
        pendingSpawnKeys: [],
        followingSteps: [],
        lastStallFinding: null,
        lastUpdatedAt: '2026-07-02T10:00:00.000Z',
      },
    })

    // A planner already decided nextStep: null — the run is genuinely done,
    // not stuck, even though there are no active workers or open requests.
    expect(result.plan).toBeNull()
    expect(result.nextState.phase).toBe('completed')
    expect(result.nextState.lastPlanSummary).toBe('The run finished successfully.')
  })
})
