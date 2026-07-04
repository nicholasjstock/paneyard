import { describe, expect, test } from 'vitest'

import {
  appendOrchestratorTickHistory,
  buildWorkflowContext,
  buildGuardedCommand,
  buildRecordDemoCommand,
  collectWorkflowState,
  queueLongPhoneDemoPlannerJob,
  readOrchestratorState,
  readOrchestratorTickHistory,
  publishPlannerJobs,
  writeOrchestratorState,
  type OrchestratorDecisionState,
  type FileSystemAdapter,
  planWorkflowIteration,
  readWorkflowArtifact,
  writeWorkflowArtifact,
} from '../workflow-mcp'

function createMemoryFs(): FileSystemAdapter {
  const files = new Map<string, { content: string; mtime: Date }>()

  return {
    mkdirSync() {},
    writeFileSync(filePath, content) {
      files.set(filePath, { content, mtime: new Date('2026-07-01T00:00:00.000Z') })
    },
    readFileSync(filePath) {
      const entry = files.get(filePath)
      if (!entry) {
        throw new Error(`missing file: ${filePath}`)
      }

      return entry.content
    },
    existsSync(filePath) {
      return files.has(filePath)
    },
    statSync(filePath) {
      const entry = files.get(filePath)
      if (!entry) {
        throw new Error(`missing file: ${filePath}`)
      }

      return {
        size: entry.content.length,
        mtime: entry.mtime,
      }
    },
  }
}

function createPreviewFs(): FileSystemAdapter {
  const content = 'x'.repeat(5000)
  const files = new Map<string, { content: string; mtime: Date }>()
  const tracker = {
    openedFiles: [] as string[],
    closedFiles: [] as Array<string | number>,
    reads: [] as Array<{ length: number; position: number | null }>,
  }

  files.set('/virtual-repo/front/demo-output/agents-sdk/run-1/recorder-report.md', {
    content,
    mtime: new Date('2026-07-01T00:00:00.000Z'),
  })

  return {
    mkdirSync() {},
    writeFileSync() {},
    readFileSync(filePath) {
      if (filePath.endsWith('recorder-report.md')) {
        throw new Error('full read should not be used for preview collection')
      }

      const entry = files.get(filePath)
      if (!entry) {
        throw new Error(`missing file: ${filePath}`)
      }

      return entry.content
    },
    existsSync(filePath) {
      return files.has(filePath)
    },
    statSync(filePath) {
      const entry = files.get(filePath)
      if (!entry) {
        throw new Error(`missing file: ${filePath}`)
      }

      return {
        size: entry.content.length,
        mtime: entry.mtime,
      }
    },
    openSync(filePath) {
      tracker.openedFiles.push(filePath)
      return filePath
    },
    readSync(fd, buffer, offset, length, position) {
      tracker.reads.push({ length, position })
      const entry = files.get(String(fd))
      if (!entry) {
        throw new Error(`missing file descriptor: ${fd}`)
      }

      const slice = entry.content.slice(position ?? 0, (position ?? 0) + length)
      const encoded = new TextEncoder().encode(slice)
      buffer.set(encoded, offset)
      return encoded.length
    },
    closeSync(fd) {
      tracker.closedFiles.push(fd)
    },
  }
}

describe('workflow-mcp planning helpers', () => {
  test('buildWorkflowContext returns the repo-specific workflow contract', () => {
    const context = buildWorkflowContext({
      rootDir: '/repo',
      frontDir: '/repo/front',
      outputDir: '/repo/front/demo-output/agents-sdk',
    })

    expect(context.recording.entryPoint).toBe('bin/record_demo')
    expect(context.recording.scriptPath).toBe('/repo/front/scripts/record-demo.ts')
    expect(context.workflow.agents).toEqual(['orchestrator', 'worker'])
  })

  test('planWorkflowIteration keeps the baseline record to verify flow when no fix is needed', () => {
    const plan = planWorkflowIteration({
      task: 'Validate the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    })

    expect(plan.summary).toContain('phone')
    expect(plan.steps.map((step) => step.owner)).toEqual(['orchestrator', 'worker', 'worker'])
    expect(plan.steps[0]?.artifact).toBe('workflow-plan.md')
    expect(plan.steps[1]?.successCheck).toContain('recorder-report.md')
    expect(plan.steps[2]?.dependsOnArtifacts).toEqual(['recorder-report.md'])
  })

  test('planWorkflowIteration inserts the narrowest fixer when verifier findings point at frontend-only defects', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      verifierFinding: 'Frontend-only defect: employee phone page fails to render the request state.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual([
      'orchestrator',
      'worker',
      'worker',
      'worker',
      'worker',
      'worker',
    ])
    expect(plan.steps[3]?.artifact).toBe('fix-summary.md')
    expect(plan.steps[3]?.successCheck).toContain('front/**')
    expect(plan.steps[4]?.dependsOnArtifacts).toEqual(['fix-summary.md'])
    expect(plan.steps[5]?.dependsOnArtifacts).toEqual(['recorder-report.md'])
  })

  test('planWorkflowIteration ignores raw stall context and keeps the baseline route', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      stallFinding: 'Stalled on a frontend-only defect: employee phone page fails to render the request state.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual(['orchestrator', 'worker', 'worker'])
  })

  test('planWorkflowIteration does not route infrastructure stalls directly', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the demo recording loop',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      stallFinding:
        'Docker Playwright version mismatch: the recording image ships Playwright 1.58.2 while the project depends on Playwright 1.61.1.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual(['orchestrator', 'worker', 'worker'])
  })

  test('planWorkflowIteration does not route unmatched stall blockers directly', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the demo workflow',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      stallFinding: 'Unhandled worker startup error: the orchestrator can no longer classify this blocker.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual(['orchestrator', 'worker', 'worker'])
  })

  test('publishPlannerJobs converts planner steps into spawn requests', () => {
    const bus = {
      requests: [] as Array<{ requestedRole: string; scope: string; text: string }>,
      appendSpawnRequest(args: {
        runId: string
        askedBy: string
        scope: string
        text: string
        context?: string
        requestedRole: string
        priority?: 'advisory' | 'blocking'
        tags?: string[]
      }) {
        const request = {
          requestedRole: args.requestedRole,
          scope: args.scope,
          text: args.text,
        }
        this.requests.push(request)
        return { requestId: `${this.requests.length}` }
      },
    }

    const plan = planWorkflowIteration({
      task: 'Validate the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    })

    const jobs = publishPlannerJobs(bus, {
      runId: 'demo-4',
      summary: plan.summary,
      plan,
    })

    expect(jobs.map((job) => job.step.owner)).toEqual(['worker', 'worker'])
    expect(bus.requests.map((request) => request.requestedRole)).toEqual([
      'worker',
      'worker',
    ])
    expect(bus.requests.map((request) => request.scope)).toEqual([
      'recorder-report.md',
      'verifier-report.md',
    ])
  })

  test('queueLongPhoneDemoPlannerJob creates a blocking planner seed request for the long phone demo video', () => {
    const captured: Array<{
      runId: string
      askedBy: string
      scope: string
      text: string
      context?: string
      requestedRole: string
      priority?: 'advisory' | 'blocking'
      tags?: string[]
      dependsOn?: string[]
    }> = []

    const request = queueLongPhoneDemoPlannerJob(
      {
        appendSpawnRequest(args) {
          captured.push(args)
          return {
            requestId: 'req-1',
            runId: args.runId,
            askedBy: args.askedBy,
            askedAt: '2026-07-04T00:00:00.000Z',
            scope: args.scope,
            text: args.text,
            context: args.context ?? null,
            requestedRole: args.requestedRole,
            priority: args.priority ?? 'advisory',
            status: 'open' as const,
            fulfilledBy: null,
            fulfilledAt: null,
            fulfillmentNote: null,
            fulfilledWorkerId: null,
            tags: args.tags ?? [],
            dependsOn: args.dependsOn ?? [],
          }
        },
      },
      {
        runId: 'demo-phone-long',
        frontendUrl: 'http://localhost:5174',
      }
    )

    expect(request.requestId).toBe('req-1')
    expect(captured).toHaveLength(1)
    expect(captured[0]).toMatchObject({
      runId: 'demo-phone-long',
      askedBy: 'user',
      scope: 'workflow-plan.md',
      requestedRole: 'planner',
      priority: 'blocking',
    })
    expect(captured[0]?.text).toContain('Create the long phone demo video')
    expect(captured[0]?.context).toContain('long phone demo video')
  })

  function createDependencyTestBus() {
    const requests: Array<{
      requestId: string
      runId: string
      askedBy: string
      scope: string
      text: string
      requestedRole: string
      dependsOn: string[]
      status: 'open' | 'fulfilled' | 'dismissed'
    }> = []
    let nextId = 1

    return {
      requests,
      appendSpawnRequest(args: {
        runId: string
        askedBy: string
        scope: string
        text: string
        requestedRole: string
        dependsOn?: string[]
      }) {
        const requestId = `req-${nextId}`
        nextId += 1
        requests.push({
          requestId,
          runId: args.runId,
          askedBy: args.askedBy,
          scope: args.scope,
          text: args.text,
          requestedRole: args.requestedRole,
          dependsOn: args.dependsOn ?? [],
          status: 'open',
        })
        return { requestId }
      },
      listOpenSpawnRequests() {
        return requests.filter((request) => request.status === 'open')
      },
      listSpawnRequests() {
        return requests
      },
      fulfillSpawnRequest({ requestId }: { requestId: string }) {
        const request = requests.find((entry) => entry.requestId === requestId)
        if (request) {
          request.status = 'fulfilled'
        }
      },
    }
  }

  test('publishPlannerJobs resolves dependsOnArtifacts to requestIds within the same batch', () => {
    const bus = createDependencyTestBus()

    const jobs = publishPlannerJobs(bus, {
      runId: 'demo-5',
      summary: 'Repair the recording loop.',
      plan: {
        summary: 'Repair the recording loop.',
        steps: [
          { owner: 'worker', artifact: 'colima-status.md', successCheck: 'colima is running' },
          {
            owner: 'worker',
            artifact: 'recorder-report.md',
            successCheck: 'recording succeeds',
            dependsOnArtifacts: ['colima-status.md'],
          },
        ],
      },
    })

    const infraJob = jobs.find((job) => job.step.artifact === 'colima-status.md')
    const recorderRequest = bus.requests.find((request) => request.scope === 'recorder-report.md')

    expect(infraJob).toBeDefined()
    expect(recorderRequest?.dependsOn).toEqual([infraJob?.requestId])
  })

  test('publishPlannerJobs resolves dependsOnArtifacts against a request already on the bus from an earlier call', () => {
    const bus = createDependencyTestBus()
    bus.appendSpawnRequest({
      runId: 'demo-6',
      askedBy: 'planner',
      scope: 'colima-status.md',
      text: 'colima is running',
      requestedRole: 'worker',
    })

    publishPlannerJobs(bus, {
      runId: 'demo-6',
      summary: 'Retry the recording after the infra fix.',
      plan: {
        summary: 'Retry the recording after the infra fix.',
        steps: [
          {
            owner: 'worker',
            artifact: 'recorder-report.md',
            successCheck: 'recording succeeds',
            dependsOnArtifacts: ['colima-status.md'],
          },
        ],
      },
    })

    const infraRequest = bus.requests.find((request) => request.scope === 'colima-status.md')
    const recorderRequest = bus.requests.find((request) => request.scope === 'recorder-report.md')

    expect(recorderRequest?.dependsOn).toEqual([infraRequest?.requestId])
  })

  test('publishPlannerJobs does not re-request a step whose earlier identical request was already fulfilled', () => {
    const bus = createDependencyTestBus()

    const step = { owner: 'worker' as const, artifact: 'recorder-report.md', successCheck: 'recording succeeds' }

    const firstJobs = publishPlannerJobs(bus, {
      runId: 'demo-7',
      summary: 'Record the demo.',
      plan: { summary: 'Record the demo.', steps: [step] },
    })

    bus.fulfillSpawnRequest({ requestId: firstJobs[0]!.requestId })

    const secondJobs = publishPlannerJobs(bus, {
      runId: 'demo-7',
      summary: 'Record the demo.',
      plan: { summary: 'Record the demo.', steps: [step] },
    })

    expect(secondJobs[0]?.requestId).toBe(firstJobs[0]?.requestId)
    expect(bus.requests).toHaveLength(1)
  })

  test('buildRecordDemoCommand chooses the right entrypoint for docker and local runs', () => {
    expect(
      buildRecordDemoCommand({
        scenario: 'phone',
        executionMode: 'docker',
        frontendUrl: 'http://localhost:5174',
      })
    ).toBe('HEADLESS=1 bin/record_demo phone --docker --frontend-url=http://localhost:5174')

    expect(
      buildRecordDemoCommand({
        scenario: 'admin',
        executionMode: 'local',
        frontendUrl: 'http://localhost:5174',
      })
    ).toBe('HEADLESS=1 bin/record_demo admin --local --frontend-url=http://localhost:5174')
  })

  test('writeWorkflowArtifact and readWorkflowArtifact reject unsafe artifact names', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    writeWorkflowArtifact(context, 'run-1', 'workflow-plan.md', '# plan\n', fileSystem)

    expect(readWorkflowArtifact(context, 'run-1', 'workflow-plan.md', fileSystem)).toBe('# plan\n')
    expect(() => writeWorkflowArtifact(context, 'run-1', '../escape.md', 'x', fileSystem)).toThrow('Unsafe workflow artifact name')
    expect(() => writeWorkflowArtifact(context, 'run-1', 'nested/path.md', 'x', fileSystem)).toThrow('Unsafe workflow artifact name')
  })

  test('writeWorkflowArtifact namespaces artifacts per run so concurrent runs cannot collide', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    writeWorkflowArtifact(context, 'run-1', 'fix-summary.md', 'run 1 fix', fileSystem)
    writeWorkflowArtifact(context, 'run-2', 'fix-summary.md', 'run 2 fix', fileSystem)

    expect(readWorkflowArtifact(context, 'run-1', 'fix-summary.md', fileSystem)).toBe('run 1 fix')
    expect(readWorkflowArtifact(context, 'run-2', 'fix-summary.md', fileSystem)).toBe('run 2 fix')
  })

  test('writeOrchestratorState and readOrchestratorState persist decision state per run', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })
    const orchestratorState: OrchestratorDecisionState = {
      runId: 'demo-2026-07-03',
      phase: 'planning',
      tickCount: 2,
      lastPlanSummary: 'Latest planner summary.',
      pendingSpawnKeys: ['["demo-2026-07-03","worker","recorder-report.md"]'],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: '2026-07-03T12:00:00.000Z',
    }

    const statePath = writeOrchestratorState(context, orchestratorState, fileSystem)

    expect(statePath).toContain('/orchestrator-state/demo-2026-07-03.json')
    expect(readOrchestratorState(context, 'demo-2026-07-03', fileSystem)).toEqual(orchestratorState)
  })

  test('readOrchestratorState returns an empty default when no state file exists', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    expect(readOrchestratorState(context, 'demo-2026-07-03', fileSystem)).toEqual({
      runId: 'demo-2026-07-03',
      phase: 'starting',
      tickCount: 0,
      lastPlanSummary: null,
      pendingSpawnKeys: [],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: null,
    })
  })

  test('appendOrchestratorTickHistory appends an entry and readOrchestratorTickHistory returns it in order', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })
    const firstTick: OrchestratorDecisionState = {
      runId: 'demo-2026-07-03',
      phase: 'planning',
      tickCount: 1,
      lastPlanSummary: 'First tick summary.',
      pendingSpawnKeys: [],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: '2026-07-03T12:00:00.000Z',
    }
    const secondTick: OrchestratorDecisionState = {
      ...firstTick,
      tickCount: 2,
      lastPlanSummary: 'Second tick summary.',
      lastUpdatedAt: '2026-07-03T12:05:00.000Z',
    }

    appendOrchestratorTickHistory(context, firstTick, fileSystem)
    appendOrchestratorTickHistory(context, secondTick, fileSystem)

    expect(readOrchestratorTickHistory(context, 'demo-2026-07-03', fileSystem)).toEqual({
      runId: 'demo-2026-07-03',
      entries: [firstTick, secondTick],
    })
  })

  test('appendOrchestratorTickHistory caps history at the configured limit, dropping the oldest entries', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })
    const buildTick = (tickCount: number): OrchestratorDecisionState => ({
      runId: 'demo-2026-07-03',
      phase: 'planning',
      tickCount,
      lastPlanSummary: `Tick ${tickCount} summary.`,
      pendingSpawnKeys: [],
      recommendedNextSteps: [],
      lastStallFinding: null,
      lastUpdatedAt: `2026-07-03T12:0${tickCount}:00.000Z`,
    })

    for (let tickCount = 1; tickCount <= 3; tickCount += 1) {
      appendOrchestratorTickHistory(context, buildTick(tickCount), fileSystem, 2)
    }

    const history = readOrchestratorTickHistory(context, 'demo-2026-07-03', fileSystem)
    expect(history.entries.map((entry) => entry.tickCount)).toEqual([2, 3])
  })

  test('readOrchestratorTickHistory returns an empty list when no history file exists', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    expect(readOrchestratorTickHistory(context, 'demo-2026-07-03', fileSystem)).toEqual({
      runId: 'demo-2026-07-03',
      entries: [],
    })
  })

  test('readOrchestratorTickHistory returns an empty list when the history file is malformed JSON', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    fileSystem.mkdirSync(`${tempRoot}/front/demo-output/agents-sdk/orchestrator-state`, { recursive: true })
    fileSystem.writeFileSync(
      `${tempRoot}/front/demo-output/agents-sdk/orchestrator-state/demo-2026-07-03.history.json`,
      'not json'
    )

    expect(readOrchestratorTickHistory(context, 'demo-2026-07-03', fileSystem)).toEqual({
      runId: 'demo-2026-07-03',
      entries: [],
    })
  })

  test('collectWorkflowState reports artifact presence and file metadata', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    writeWorkflowArtifact(context, 'run-1', 'recorder-report.md', 'recorded ok', fileSystem)

    const state = collectWorkflowState(context, 'run-1', ['recorder-report.md', 'verifier-report.md'], fileSystem)

    expect(state.artifacts.find((artifact) => artifact.name === 'recorder-report.md')).toMatchObject({
      exists: true,
      preview: 'recorded ok',
    })
    expect(state.artifacts.find((artifact) => artifact.name === 'verifier-report.md')).toMatchObject({
      exists: false,
    })
  })

  test('collectWorkflowState reads only a bounded preview for existing artifacts', () => {
    const fileSystem = createPreviewFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    const state = collectWorkflowState(context, 'run-1', ['recorder-report.md'], fileSystem)

    expect(state.artifacts.find((artifact) => artifact.name === 'recorder-report.md')).toMatchObject({
      exists: true,
      preview: 'x'.repeat(200),
    })
  })

  test('buildGuardedCommand only allows repo-specific environment operations', () => {
    expect(
      buildGuardedCommand({
        operation: 'frontend_typecheck',
        rootDir: '/repo',
        frontDir: '/repo/front',
      })
    ).toEqual({
      command: 'npx',
      args: ['tsc', '--noEmit'],
      cwd: '/repo/front',
    })

    expect(
      buildGuardedCommand({
        operation: 'record_demo',
        rootDir: '/repo',
        frontDir: '/repo/front',
        scenario: 'phone',
        executionMode: 'docker',
        frontendUrl: 'http://localhost:5174',
      })
    ).toEqual({
      command: 'bin/record_demo',
      args: ['phone', '--docker', '--frontend-url=http://localhost:5174'],
      cwd: '/repo',
    })
  })
})
