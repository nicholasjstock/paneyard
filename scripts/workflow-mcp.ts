import * as fs from 'fs'

export type DemoScenario = 'admin' | 'phone' | 'both'
export type ExecutionMode = 'local' | 'docker'
export type GuardedOperation = 'record_demo' | 'frontend_typecheck' | 'frontend_test'
export type WorkflowAgent =
  | 'orchestrator'
  | 'demo_recorder'
  | 'demo_verifier'
  | 'front_fixer'
  | 'back_fixer'
  | 'infra_fixer'
  | 'general_fixer'

export type WorkflowStep = {
  owner: WorkflowAgent
  artifact: string
  successCheck: string
}

export type WorkflowContext = {
  workspace: {
    rootDir: string
    frontDir: string
    outputDir: string
  }
  recording: {
    entryPoint: string
    scriptPath: string
    runbookPath: string
  }
  workflow: {
    agents: WorkflowAgent[]
    artifacts: string[]
    preferredLoop: string[]
  }
}

export type PlanWorkflowIterationArgs = {
  task: string
  scenario: DemoScenario
  frontendUrl: string
  verifierFinding?: string
  stallFinding?: string
}

export type PlanWorkflowIterationResult = {
  summary: string
  steps: WorkflowStep[]
}

export type PlannerBusJob = {
  step: WorkflowStep
  requestId: string
}

export type BuildRecordDemoCommandArgs = {
  scenario: DemoScenario
  executionMode: ExecutionMode
  frontendUrl: string
}

export type WorkflowArtifactState = {
  name: string
  path: string
  exists: boolean
  sizeBytes: number | null
  updatedAt: string | null
  preview: string | null
}

export type WorkflowState = {
  outputDir: string
  artifacts: WorkflowArtifactState[]
}

export type OrchestratorDecisionPhase =
  | 'starting'
  | 'planning'
  | 'waiting_on_workers'
  | 'stalled'
  | 'completed'

export type OrchestratorDecisionState = {
  runId: string
  phase: OrchestratorDecisionPhase
  tickCount: number
  lastPlanSummary: string | null
  pendingSpawnKeys: string[]
  lastStallFinding: string | null
  lastUpdatedAt: string | null
}

export type BuildGuardedCommandArgs = {
  operation: GuardedOperation
  rootDir: string
  frontDir: string
  scenario?: DemoScenario
  executionMode?: ExecutionMode
  frontendUrl?: string
  testTarget?: string
}

export type GuardedCommand = {
  command: string
  args: string[]
  cwd: string
}

export type FileSystemAdapter = {
  mkdirSync(dir: string, options?: { recursive?: boolean }): void
  writeFileSync(filePath: string, content: string): void
  readFileSync(filePath: string, encoding: BufferEncoding): string
  existsSync(filePath: string): boolean
  statSync(filePath: string): { size: number; mtime: Date }
  openSync?(path: string, flags: string | number): string | number
  readSync?(fd: string | number, buffer: Uint8Array, offset: number, length: number, position: number | null): number
  closeSync?(fd: string | number): void
}

const defaultFileSystemAdapter: FileSystemAdapter = {
  mkdirSync(dir, options) {
    fs.mkdirSync(dir, options)
  },
  writeFileSync(filePath, content) {
    fs.writeFileSync(filePath, content)
  },
  readFileSync(filePath, encoding) {
    return fs.readFileSync(filePath, encoding)
  },
  existsSync(filePath) {
    return fs.existsSync(filePath)
  },
  statSync(filePath) {
    return fs.statSync(filePath)
  },
  openSync(filePath, flags) {
    return fs.openSync(filePath, flags)
  },
  readSync(fd, buffer, offset, length, position) {
    return fs.readSync(fd as number, buffer, offset, length, position)
  },
  closeSync(fd) {
    fs.closeSync(fd as number)
  },
}

export function buildWorkflowContext(args: {
  rootDir: string
  frontDir: string
  outputDir: string
}): WorkflowContext {
  return {
    workspace: {
      rootDir: args.rootDir,
      frontDir: args.frontDir,
      outputDir: args.outputDir,
    },
    recording: {
      entryPoint: 'bin/record_demo',
      scriptPath: `${args.frontDir}/scripts/record-demo.ts`,
      runbookPath: `${args.rootDir}/handoff/demo-video-openclaw.md`,
    },
    workflow: {
      agents: [
        'orchestrator',
        'demo_recorder',
        'demo_verifier',
        'front_fixer',
        'back_fixer',
        'infra_fixer',
        'general_fixer',
      ],
      artifacts: [
        'workflow-plan.md',
        'recorder-report.md',
        'verifier-report.md',
        'fix-summary.md',
        'final-summary.md',
      ],
      preferredLoop: ['record', 'verify', 'fix-if-needed', 're-record', 're-verify'],
    },
  }
}

export function planWorkflowIteration(args: PlanWorkflowIterationArgs): PlanWorkflowIterationResult {
  const findingText = [args.verifierFinding, args.stallFinding].filter(Boolean).join('\n').toLowerCase()
  const steps: WorkflowStep[] = [
    {
      owner: 'orchestrator',
      artifact: 'workflow-plan.md',
      successCheck: `Defines the next owner, required artifact, and scenario ${args.scenario} before any specialist work begins.`,
    },
    {
      owner: 'demo_recorder',
      artifact: 'recorder-report.md',
      successCheck: `Runs ${buildRecordDemoCommand({
        scenario: args.scenario,
        executionMode: 'docker',
        frontendUrl: args.frontendUrl,
      })} and writes recorder-report.md with artifact paths plus exit status.`,
    },
    {
      owner: 'demo_verifier',
      artifact: 'verifier-report.md',
      successCheck: 'Confirms visible UI state transitions and cites positive evidence from generated artifacts.',
    },
  ]

  if (findingText.includes('frontend')) {
    steps.push({
      owner: 'front_fixer',
      artifact: 'fix-summary.md',
      successCheck: 'Adds or updates the preferred frontend test first, then lands the narrowest front/** fix.',
    })
    steps.push({
      owner: 'demo_recorder',
      artifact: 'recorder-report.md',
      successCheck: 'Re-runs the recording flow after the frontend fix.',
    })
    steps.push({
      owner: 'demo_verifier',
      artifact: 'verifier-report.md',
      successCheck: 'Verifies the latest artifacts support success after the frontend fix.',
    })
  } else if (findingText.includes('backend')) {
    steps.push({
      owner: 'back_fixer',
      artifact: 'fix-summary.md',
      successCheck: 'Adds or updates a failing request spec first, then lands the narrowest back/** fix.',
    })
    steps.push({
      owner: 'demo_recorder',
      artifact: 'recorder-report.md',
      successCheck: 'Re-runs the recording flow after the backend fix.',
    })
    steps.push({
      owner: 'demo_verifier',
      artifact: 'verifier-report.md',
      successCheck: 'Verifies the latest artifacts support success after the backend fix.',
    })
  } else if (
    findingText.includes('playwright') ||
    findingText.includes('docker') ||
    findingText.includes('infrastructure') ||
    findingText.includes('toolchain')
  ) {
    steps.push({
      owner: 'infra_fixer',
      artifact: 'fix-summary.md',
      successCheck: 'Adds or updates the preferred infrastructure test first, then lands the narrowest repo-local toolchain or environment fix.',
    })
    steps.push({
      owner: 'demo_recorder',
      artifact: 'recorder-report.md',
      successCheck: 'Re-runs the recording flow after the infrastructure fix.',
    })
    steps.push({
      owner: 'demo_verifier',
      artifact: 'verifier-report.md',
      successCheck: 'Verifies the latest artifacts support success after the infrastructure fix.',
    })
  } else if (findingText.trim().length > 0) {
    steps.push({
      owner: 'general_fixer',
      artifact: 'fix-summary.md',
      successCheck: 'Adds or updates the narrowest repo-wide regression test first, then lands the smallest general-purpose fix.',
    })
    steps.push({
      owner: 'demo_recorder',
      artifact: 'recorder-report.md',
      successCheck: 'Re-runs the recording flow after the general fix.',
    })
    steps.push({
      owner: 'demo_verifier',
      artifact: 'verifier-report.md',
      successCheck: 'Verifies the latest artifacts support success after the general fix.',
    })
  }

  return {
    summary: `${args.task} for the ${args.scenario} scenario against ${args.frontendUrl}.`,
    steps,
  }
}

export function publishPlannerJobs(
  bus: {
    appendSpawnRequest: (args: {
      runId: string
      askedBy: string
      scope: string
      text: string
      context?: string
      requestedRole: string
      priority?: 'advisory' | 'blocking'
      tags?: string[]
    }) => { requestId: string }
    listOpenSpawnRequests?: () => Array<{
      requestId: string
      runId: string
      askedBy: string
      scope: string
      text: string
      requestedRole: string
      status: 'open' | 'fulfilled' | 'dismissed'
    }>
  },
  args: {
    runId: string
    summary: string
    plan: PlanWorkflowIterationResult
  }
): PlannerBusJob[] {
  return args.plan.steps
    .filter((step) => step.owner !== 'orchestrator')
    .map((step) => {
      const existingRequest = bus
        .listOpenSpawnRequests?.()
        .find(
          (request) =>
            request.status === 'open' &&
            request.askedBy === 'planner' &&
            request.runId === args.runId &&
            request.requestedRole === step.owner &&
            request.scope === step.artifact &&
            request.text === step.successCheck
        )

      if (existingRequest) {
        return {
          step,
          requestId: existingRequest.requestId,
        }
      }

      const request = bus.appendSpawnRequest({
        runId: args.runId,
        askedBy: 'planner',
        scope: step.artifact,
        text: step.successCheck,
        context: args.summary,
        requestedRole: step.owner,
        priority: 'blocking',
        tags: [step.owner, step.artifact, 'planner-job'],
      })

      return {
        step,
        requestId: request.requestId,
      }
    })
}

export function buildRecordDemoCommand(args: BuildRecordDemoCommandArgs): string {
  const parts = ['HEADLESS=1 bin/record_demo', args.scenario, `--${args.executionMode}`, `--frontend-url=${args.frontendUrl}`]

  return parts.join(' ')
}

export function resolveWorkflowArtifactPath(context: WorkflowContext, artifactName: string): string {
  if (!context.workflow.artifacts.includes(artifactName)) {
    throw new Error(`Unsupported workflow artifact: ${artifactName}`)
  }

  return `${context.workspace.outputDir.replace(/\/$/, '')}/${artifactName}`
}

function sanitizeRunId(runId: string): string {
  const sanitized = runId.trim().replace(/[^A-Za-z0-9._-]/g, '_')
  if (sanitized.length === 0) {
    throw new Error('runId must not be empty')
  }

  return sanitized
}

function buildDefaultOrchestratorState(runId: string): OrchestratorDecisionState {
  return {
    runId,
    phase: 'starting',
    tickCount: 0,
    lastPlanSummary: null,
    pendingSpawnKeys: [],
    lastStallFinding: null,
    lastUpdatedAt: null,
  }
}

export function resolveOrchestratorStatePath(context: WorkflowContext, runId: string): string {
  return `${context.workspace.outputDir.replace(/\/$/, '')}/orchestrator-state/${sanitizeRunId(runId)}.json`
}

export type OrchestratorTickHistory = {
  runId: string
  entries: OrchestratorDecisionState[]
}

export const ORCHESTRATOR_TICK_HISTORY_LIMIT = 200

export function resolveOrchestratorTickHistoryPath(context: WorkflowContext, runId: string): string {
  return `${context.workspace.outputDir.replace(/\/$/, '')}/orchestrator-state/${sanitizeRunId(runId)}.history.json`
}

export function appendOrchestratorTickHistory(
  context: WorkflowContext,
  entry: OrchestratorDecisionState,
  fileSystem: Pick<FileSystemAdapter, 'existsSync' | 'mkdirSync' | 'readFileSync' | 'writeFileSync'> = defaultFileSystemAdapter,
  limit: number = ORCHESTRATOR_TICK_HISTORY_LIMIT
): string {
  const previousHistory = readOrchestratorTickHistory(context, entry.runId, fileSystem)
  const entries = [...previousHistory.entries, entry].slice(-limit)
  const historyPath = resolveOrchestratorTickHistoryPath(context, entry.runId)
  const historyDir = historyPath.slice(0, historyPath.lastIndexOf('/'))
  fileSystem.mkdirSync(historyDir, { recursive: true })
  fileSystem.writeFileSync(historyPath, `${JSON.stringify(entries, null, 2)}\n`)
  return historyPath
}

export function readOrchestratorTickHistory(
  context: WorkflowContext,
  runId: string,
  fileSystem: Pick<FileSystemAdapter, 'existsSync' | 'readFileSync'> = defaultFileSystemAdapter
): OrchestratorTickHistory {
  const historyPath = resolveOrchestratorTickHistoryPath(context, runId)
  if (!fileSystem.existsSync(historyPath)) {
    return { runId, entries: [] }
  }

  try {
    const parsed = JSON.parse(fileSystem.readFileSync(historyPath, 'utf8')) as unknown
    if (!Array.isArray(parsed)) {
      return { runId, entries: [] }
    }

    return { runId, entries: parsed as OrchestratorDecisionState[] }
  } catch {
    return { runId, entries: [] }
  }
}

export function writeWorkflowArtifact(
  context: WorkflowContext,
  artifactName: string,
  content: string,
  fileSystem: FileSystemAdapter = defaultFileSystemAdapter
): string {
  const artifactPath = resolveWorkflowArtifactPath(context, artifactName)
  fileSystem.mkdirSync(context.workspace.outputDir, { recursive: true })
  fileSystem.writeFileSync(artifactPath, content)
  return artifactPath
}

export function readWorkflowArtifact(
  context: WorkflowContext,
  artifactName: string,
  fileSystem: Pick<FileSystemAdapter, 'readFileSync'>
): string
export function readWorkflowArtifact(context: WorkflowContext, artifactName: string): string
export function readWorkflowArtifact(
  context: WorkflowContext,
  artifactName: string,
  fileSystem: Pick<FileSystemAdapter, 'readFileSync'> = defaultFileSystemAdapter
): string {
  const artifactPath = resolveWorkflowArtifactPath(context, artifactName)
  return fileSystem.readFileSync(artifactPath, 'utf8')
}

export function writeOrchestratorState(
  context: WorkflowContext,
  state: OrchestratorDecisionState,
  fileSystem: Pick<FileSystemAdapter, 'mkdirSync' | 'writeFileSync'> = defaultFileSystemAdapter
): string {
  const statePath = resolveOrchestratorStatePath(context, state.runId)
  const stateDir = statePath.slice(0, statePath.lastIndexOf('/'))
  fileSystem.mkdirSync(stateDir, { recursive: true })
  fileSystem.writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`)
  return statePath
}

export function readOrchestratorState(
  context: WorkflowContext,
  runId: string,
  fileSystem: Pick<FileSystemAdapter, 'existsSync' | 'readFileSync'> = defaultFileSystemAdapter
): OrchestratorDecisionState {
  const statePath = resolveOrchestratorStatePath(context, runId)
  if (!fileSystem.existsSync(statePath)) {
    return buildDefaultOrchestratorState(runId)
  }

  try {
    const parsed = JSON.parse(fileSystem.readFileSync(statePath, 'utf8')) as Partial<OrchestratorDecisionState>

    return {
      runId,
      phase: parsed.phase ?? 'starting',
      tickCount: typeof parsed.tickCount === 'number' ? parsed.tickCount : 0,
      lastPlanSummary: parsed.lastPlanSummary ?? null,
      pendingSpawnKeys: Array.isArray(parsed.pendingSpawnKeys)
        ? parsed.pendingSpawnKeys.filter((entry): entry is string => typeof entry === 'string')
        : [],
      lastStallFinding: parsed.lastStallFinding ?? null,
      lastUpdatedAt: parsed.lastUpdatedAt ?? null,
    }
  } catch {
    return buildDefaultOrchestratorState(runId)
  }
}

export function collectWorkflowState(
  context: WorkflowContext,
  fileSystem: FileSystemAdapter = defaultFileSystemAdapter
): WorkflowState {
  function readPreview(filePath: string): string {
    if (fileSystem.openSync && fileSystem.readSync && fileSystem.closeSync) {
      const fd = fileSystem.openSync(filePath, 'r')
      const previewBuffer = new Uint8Array(200)
      const decoder = new TextDecoder()

      try {
        const bytesRead = fileSystem.readSync(fd, previewBuffer, 0, previewBuffer.length, 0)
        return decoder.decode(previewBuffer.subarray(0, bytesRead))
      } finally {
        fileSystem.closeSync(fd)
      }
    }

    return fileSystem.readFileSync(filePath, 'utf8').slice(0, 200)
  }

  return {
    outputDir: context.workspace.outputDir,
    artifacts: context.workflow.artifacts.map((name) => {
      const artifactPath = resolveWorkflowArtifactPath(context, name)

      if (!fileSystem.existsSync(artifactPath)) {
        return {
          name,
          path: artifactPath,
          exists: false,
          sizeBytes: null,
          updatedAt: null,
          preview: null,
        }
      }

      const stat = fileSystem.statSync(artifactPath)

      return {
        name,
        path: artifactPath,
        exists: true,
        sizeBytes: stat.size,
        updatedAt: stat.mtime.toISOString(),
        preview: readPreview(artifactPath),
      }
    }),
  }
}

export function buildGuardedCommand(args: BuildGuardedCommandArgs): GuardedCommand {
  switch (args.operation) {
    case 'frontend_typecheck':
      return {
        command: 'npx',
        args: ['tsc', '--noEmit'],
        cwd: args.frontDir,
      }
    case 'frontend_test':
      return {
        command: 'npm',
        args: ['test', '--', ...(args.testTarget ? [args.testTarget] : [])],
        cwd: args.frontDir,
      }
    case 'record_demo':
      if (!args.scenario || !args.executionMode || !args.frontendUrl) {
        throw new Error('record_demo requires scenario, executionMode, and frontendUrl')
      }

      return {
        command: 'bin/record_demo',
        args: [args.scenario, `--${args.executionMode}`, `--frontend-url=${args.frontendUrl}`],
        cwd: args.rootDir,
      }
  }
}
