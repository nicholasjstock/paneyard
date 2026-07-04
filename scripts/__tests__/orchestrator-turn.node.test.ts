// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowBus } from '../workflow-bus'
import { runOrchestratorTurn } from '../orchestrator-turn'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('orchestrator turn', () => {
  test('detects a stalled worker and publishes a planner recovery job', () => {
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
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
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
      path.join(outputDir, 'workers.json'),
      JSON.stringify({ workers: [workerRecord] }, null, 2)
    )
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

    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
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
    const bus = createWorkflowBus({ storagePath: busStoragePath })
    const result = runOrchestratorTurn({
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
    expect(bus.listOpenSpawnRequests().map((request) => request.requestedRole)).toContain('planner')
  })

  test('repeated ticks on the same stall do not pile up duplicate planner recovery requests', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const workersDir = path.join(outputDir, 'workers')
    fs.mkdirSync(workersDir, { recursive: true })

    const logPath = path.join(workersDir, 'worker.log')
    const lastMessagePath = path.join(workersDir, 'worker.last-message.txt')
    const promptPath = path.join(workersDir, 'worker.prompt.txt')
    const envPath = path.join(workersDir, 'worker.env.json')
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
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
      path.join(outputDir, 'workers.json'),
      JSON.stringify({ workers: [workerRecord] }, null, 2)
    )
    fs.writeFileSync(logPath, 'worker is still waiting on a browser frame')
    fs.writeFileSync(lastMessagePath, 'Waiting on the browser frame to move.')
    fs.writeFileSync(promptPath, 'Fix the stalled frontend recorder path.')
    fs.writeFileSync(envPath, '{}')

    const staleAt = new Date('2026-07-02T10:00:00.000Z')
    fs.utimesSync(logPath, staleAt, staleAt)
    fs.utimesSync(lastMessagePath, staleAt, staleAt)
    fs.utimesSync(promptPath, staleAt, staleAt)

    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
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
    const bus = createWorkflowBus({ storagePath: busStoragePath })

    // Two ticks on the exact same still-stalled worker, 5s apart — idleForMs
    // (baked into the recovery successCheck text) differs between the two,
    // but the underlying ask ("recover this stall") has not changed.
    runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:00.000Z'),
    })
    const secondTick = runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: runtime,
      bus,
      fileSystem: fs,
      now: new Date('2026-07-02T10:05:05.000Z'),
    })

    const plannerRequests = bus.listOpenSpawnRequests().filter((request) => request.requestedRole === 'planner')
    expect(plannerRequests).toHaveLength(1)
    expect(secondTick.jobs.map((job) => job.step.owner)).toEqual(['planner'])
    expect(secondTick.jobs[0]?.requestId).toBe(plannerRequests[0]?.requestId)
  })

  test('does not spawn planner workers during the orchestrator tick', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const workersDir = path.join(outputDir, 'workers')
    fs.mkdirSync(workersDir, { recursive: true })

    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })
    const runId = 'demo-20260702-130619'

    bus.appendSpawnRequest({
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

    fs.writeFileSync(
      path.join(outputDir, 'workers.json'),
      JSON.stringify({ workers: [activeRecorder, activeVerifier] }, null, 2)
    )

    const spawned: Array<{ role: string; nickname: string; scope: string; reason: string; prompt: string }> = []

    const result = runOrchestratorTurn({
      runId,
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        listWorkers() {
          return [activeRecorder, activeVerifier]
        },
        spawnWorker(args) {
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
    expect(bus.listRecentEvents(10).map((event) => event.type)).not.toContain('worker.spawned')
  })

  test('does not spawn missing workers for open planner jobs in the same turn', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })
    const spawned: Array<{ role: string; nickname: string; scope: string; reason: string; prompt: string }> = []

    const result = runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        listWorkers() {
          return []
        },
        spawnWorker(args) {
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
    expect(bus.listRecentEvents(5).map((event) => event.type)).not.toContain('worker.spawned')
  })

  test('does not append duplicate open planner jobs for the same run, role, and scope', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })

    const workerRuntime = {
      listWorkers() {
        return []
      },
      spawnWorker() {
        throw new Error('orchestrator turn should not spawn workers')
      },
    }

    runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
    })

    runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime,
      bus,
      fileSystem: fs,
    })

    expect(
      bus
        .listOpenSpawnRequests()
        .map((request) => [request.runId, request.requestedRole, request.scope].join('|'))
        .sort()
    ).toEqual([])
  })

  test('detects a dead end (no workers, no open requests, not completed) and asks a planner to recover', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })

    const result = runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        listWorkers() {
          return []
        },
        spawnWorker() {
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

  test('does not spawn another recovery planner while a blocking user question is already open for the run', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })

    // A prior recovery planner already escalated this exact dead end to the
    // user instead of retrying again — the orchestrator must not ignore that
    // and spawn yet another recovery planner to redundantly re-investigate
    // the same thing while it's still awaiting a human answer.
    bus.appendUserQuestion({
      runId: 'demo-20260702-130619',
      askedBy: 'planner',
      scope: 'phone-demo-video',
      text: 'Both recorder attempts stalled identically — how should I proceed?',
      priority: 'blocking',
    })

    const result = runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        listWorkers() {
          return []
        },
        spawnWorker() {
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
    expect(bus.listOpenSpawnRequests()).toEqual([])
  })

  test('does not treat a legitimately completed run as a dead end', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orchestrator-turn-'))
    tempDirs.push(tempDir)
    const busStoragePath = path.join(tempDir, 'workflow-bus.json')
    const bus = createWorkflowBus({ storagePath: busStoragePath })

    const result = runOrchestratorTurn({
      runId: 'demo-20260702-130619',
      task: 'Recover the stalled demo run',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      workerRuntime: {
        listWorkers() {
          return []
        },
        spawnWorker() {
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
