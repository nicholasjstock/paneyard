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

export type WorkflowStepOwner = WorkflowAgent | 'planner'

export type WorkflowStep = {
  owner: WorkflowStepOwner
  artifact: string
  successCheck: string
  // artifact names of other steps (in this same plan, or already on the bus
  // for this run) that must be fulfilled before this step may be spawned.
  dependsOnArtifacts?: string[]
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

export type PlannerSeedRequest = {
  requestId: string
  runId: string
  askedBy: string
  askedAt: string
  scope: string
  text: string
  context: string | null
  requestedRole: string
  priority: 'advisory' | 'blocking'
  status: 'open' | 'fulfilled' | 'dismissed'
  fulfilledBy: string | null
  fulfilledAt: string | null
  fulfillmentNote: string | null
  fulfilledWorkerId?: string | null
  tags: string[]
  dependsOn?: string[]
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

// Defaults below describe the simple-retail-planner demo-recording pipeline,
// the one downstream consumer this engine currently points at (via
// WORKFLOW_TARGET_ROOT). They are caller-supplied defaults, not part of the
// orchestrator's own domain — a different target project should pass its own
// agents/recording shape instead of relying on these. Artifact names are not
// part of this static config at all — they're decided per run by whichever
// planner is active (see WorkflowStep.artifact / listPlannerDeclaredArtifacts).
const DEFAULT_WORKFLOW_AGENTS: WorkflowAgent[] = [
  'orchestrator',
  'demo_recorder',
  'demo_verifier',
  'front_fixer',
  'back_fixer',
  'infra_fixer',
  'general_fixer',
]

const DEFAULT_PREFERRED_LOOP: string[] = ['record', 'verify', 'fix-if-needed', 're-record', 're-verify']

export function buildWorkflowContext(args: {
  rootDir: string
  frontDir: string
  outputDir: string
  agents?: WorkflowAgent[]
  preferredLoop?: string[]
  recording?: {
    entryPoint: string
    scriptPath: string
    runbookPath: string
  }
}): WorkflowContext {
  return {
    workspace: {
      rootDir: args.rootDir,
      frontDir: args.frontDir,
      outputDir: args.outputDir,
    },
    recording: args.recording ?? {
      entryPoint: 'bin/record_demo',
      scriptPath: `${args.frontDir}/scripts/record-demo.ts`,
      runbookPath: `${args.rootDir}/handoff/demo-video-openclaw.md`,
    },
    workflow: {
      agents: args.agents ?? DEFAULT_WORKFLOW_AGENTS,
      preferredLoop: args.preferredLoop ?? DEFAULT_PREFERRED_LOOP,
    },
  }
}

export function planWorkflowIteration(args: PlanWorkflowIterationArgs): PlanWorkflowIterationResult {
  const findingText = [args.verifierFinding].filter(Boolean).join('\n').toLowerCase()
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

export function buildStalledWorkerRecoveryPlan(args: {
  task: string
  scenario: DemoScenario
  frontendUrl: string
  stallFinding: string
}): PlanWorkflowIterationResult {
  const summarizedFinding = args.stallFinding.replace(/\s+/g, ' ').trim()

  return {
    summary: `${args.task} for the ${args.scenario} scenario against ${args.frontendUrl}. Recover the stalled worker via planner. ${summarizedFinding}`,
    steps: [
      {
        owner: 'orchestrator',
        artifact: 'workflow-plan.md',
        successCheck: 'Captures the stalled-worker context and requests a bounded planner recovery handoff.',
      },
      {
        owner: 'planner',
        artifact: 'workflow-plan.md',
        successCheck: `Inspect this stalled-worker context, determine the next bounded recovery handoff, and publish it with planner_turn: ${summarizedFinding}`,
      },
    ],
  }
}

export function buildWaitingPlan(args: {
  task: string
  scenario: DemoScenario
  frontendUrl: string
  activeWorkers: number
  openSpawnRequests: number
}): PlanWorkflowIterationResult {
  const statusSummary =
    args.activeWorkers === 0 && args.openSpawnRequests === 0
      ? 'No active workers or open spawn requests; remain idle until a new request arrives.'
      : `Waiting on ${args.activeWorkers} active workers and ${args.openSpawnRequests} open spawn requests.`

  return {
    summary: `${args.task} for the ${args.scenario} scenario against ${args.frontendUrl}. ${statusSummary}`,
    steps: [
      {
        owner: 'orchestrator',
        artifact: 'workflow-plan.md',
        successCheck:
          args.activeWorkers === 0 && args.openSpawnRequests === 0
            ? 'Records that the run is idle and needs no automatic restart or new handoff.'
            : 'Records that the run already has active work in flight and needs no new handoff yet.',
      },
    ],
  }
}

export function queueLongPhoneDemoPlannerJob(
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
      dependsOn?: string[]
    }) => PlannerSeedRequest
  },
  args: {
    runId: string
    frontendUrl: string
    task?: string
  }
): PlannerSeedRequest {
  const task =
    args.task?.trim() && args.task.trim().length > 0
      ? args.task.trim()
      : 'Create the long phone demo video.'

  return bus.appendSpawnRequest({
    runId: args.runId,
    askedBy: 'user',
    scope: 'workflow-plan.md',
    text: task,
    context:
      `Plan the full worker chain needed to produce the long phone demo video against ${args.frontendUrl}. ` +
      'Publish the next bounded handoff with planner_turn.',
    requestedRole: 'planner',
    priority: 'blocking',
    tags: ['planner', 'phone-demo', 'long-demo-video', 'seed-job'],
  })
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
      dependsOn?: string[]
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
    listSpawnRequests?: () => Array<{
      requestId: string
      runId: string
      scope: string
    }>
  },
  args: {
    runId: string
    summary: string
    plan: PlanWorkflowIterationResult
  }
): PlannerBusJob[] {
  // Seed artifact -> requestId from anything already on the bus for this run
  // (any status) so a step can depend on an artifact requested in an earlier
  // planner_turn call, not just one in this same batch.
  const requestIdByArtifact = new Map<string, string>()
  for (const existing of bus.listSpawnRequests?.() ?? []) {
    if (existing.runId === args.runId) {
      requestIdByArtifact.set(existing.scope, existing.requestId)
    }
  }

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
        requestIdByArtifact.set(step.artifact, existingRequest.requestId)
        return {
          step,
          requestId: existingRequest.requestId,
        }
      }

      const dependsOn = (step.dependsOnArtifacts ?? [])
        .map((artifact) => requestIdByArtifact.get(artifact))
        .filter((requestId): requestId is string => Boolean(requestId))

      const request = bus.appendSpawnRequest({
        runId: args.runId,
        askedBy: 'planner',
        scope: step.artifact,
        text: step.successCheck,
        context: args.summary,
        requestedRole: step.owner,
        priority: 'blocking',
        tags: [step.owner, step.artifact, 'planner-job'],
        dependsOn,
      })

      requestIdByArtifact.set(step.artifact, request.requestId)

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
  if (
    artifactName.length === 0 ||
    artifactName === '.' ||
    artifactName === '..' ||
    artifactName.includes('/') ||
    artifactName.includes('\\') ||
    artifactName.includes('\0')
  ) {
    throw new Error(`Unsafe workflow artifact name: ${artifactName}`)
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

export function listPlannerDeclaredArtifacts(
  bus: { listSpawnRequests: () => Array<{ runId: string; askedBy: string; scope: string }> },
  runId: string
): string[] {
  const seen = new Set<string>()
  for (const request of bus.listSpawnRequests()) {
    if (request.runId === runId && request.askedBy === 'planner') {
      seen.add(request.scope)
    }
  }
  return [...seen]
}

export function collectWorkflowState(
  context: WorkflowContext,
  artifactNames: string[],
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
    artifacts: artifactNames.map((name) => {
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
