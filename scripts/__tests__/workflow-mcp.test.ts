import { describe, expect, test } from 'vitest'

import {
  appendOrchestratorTickHistory,
  buildWorkflowContext,
  buildGuardedCommand,
  buildRecordDemoCommand,
  collectWorkflowState,
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

  files.set('/virtual-repo/front/demo-output/agents-sdk/recorder-report.md', {
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
    expect(context.workflow.artifacts).toEqual([
      'workflow-plan.md',
      'recorder-report.md',
      'verifier-report.md',
      'fix-summary.md',
      'final-summary.md',
    ])
    expect(context.workflow.agents).toContain('orchestrator')
    expect(context.workflow.agents).toContain('infra_fixer')
    expect(context.workflow.agents).toContain('general_fixer')
    expect(context.workflow.agents).not.toContain('project_manager')
  })

  test('planWorkflowIteration keeps the baseline record to verify flow when no fix is needed', () => {
    const plan = planWorkflowIteration({
      task: 'Validate the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
    })

    expect(plan.summary).toContain('phone')
    expect(plan.steps.map((step) => step.owner)).toEqual(['orchestrator', 'demo_recorder', 'demo_verifier'])
    expect(plan.steps[0]?.artifact).toBe('workflow-plan.md')
    expect(plan.steps[1]?.successCheck).toContain('recorder-report.md')
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
      'demo_recorder',
      'demo_verifier',
      'front_fixer',
      'demo_recorder',
      'demo_verifier',
    ])
    expect(plan.steps[3]?.artifact).toBe('fix-summary.md')
  })

  test('planWorkflowIteration also treats stall context as planner input for frontend-only defects', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the phone demo flow',
      scenario: 'phone',
      frontendUrl: 'http://localhost:5174',
      stallFinding: 'Stalled on a frontend-only defect: employee phone page fails to render the request state.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual([
      'orchestrator',
      'demo_recorder',
      'demo_verifier',
      'front_fixer',
      'demo_recorder',
      'demo_verifier',
    ])
  })

  test('planWorkflowIteration routes infrastructure stalls to the infra fixer', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the demo recording loop',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      stallFinding:
        'Docker Playwright version mismatch: the recording image ships Playwright 1.58.2 while the project depends on Playwright 1.61.1.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual([
      'orchestrator',
      'demo_recorder',
      'demo_verifier',
      'infra_fixer',
      'demo_recorder',
      'demo_verifier',
    ])
    expect(plan.steps[3]?.artifact).toBe('fix-summary.md')
  })

  test('planWorkflowIteration routes unmatched blockers to the general fixer', () => {
    const plan = planWorkflowIteration({
      task: 'Repair the demo workflow',
      scenario: 'both',
      frontendUrl: 'http://localhost:5174',
      stallFinding: 'Unhandled worker startup error: the orchestrator can no longer classify this blocker.',
    })

    expect(plan.steps.map((step) => step.owner)).toEqual([
      'orchestrator',
      'demo_recorder',
      'demo_verifier',
      'general_fixer',
      'demo_recorder',
      'demo_verifier',
    ])
    expect(plan.steps[3]?.artifact).toBe('fix-summary.md')
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

    expect(jobs.map((job) => job.step.owner)).toEqual(['demo_recorder', 'demo_verifier'])
    expect(bus.requests.map((request) => request.requestedRole)).toEqual([
      'demo_recorder',
      'demo_verifier',
    ])
    expect(bus.requests.map((request) => request.scope)).toEqual([
      'recorder-report.md',
      'verifier-report.md',
    ])
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

  test('writeWorkflowArtifact and readWorkflowArtifact stay within the managed artifact set', () => {
    const fileSystem = createMemoryFs()
    const tempRoot = '/virtual-repo'
    const context = buildWorkflowContext({
      rootDir: tempRoot,
      frontDir: `${tempRoot}/front`,
      outputDir: `${tempRoot}/front/demo-output/agents-sdk`,
    })

    writeWorkflowArtifact(context, 'workflow-plan.md', '# plan\n', fileSystem)

    expect(readWorkflowArtifact(context, 'workflow-plan.md', fileSystem)).toBe('# plan\n')
    expect(() => writeWorkflowArtifact(context, '../escape.md', 'x', fileSystem)).toThrow('Unsupported workflow artifact')
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
      pendingSpawnKeys: ['["demo-2026-07-03","demo_recorder","recorder-report.md"]'],
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

    writeWorkflowArtifact(context, 'recorder-report.md', 'recorded ok', fileSystem)

    const state = collectWorkflowState(context, fileSystem)

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

    const state = collectWorkflowState(context, fileSystem)

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
