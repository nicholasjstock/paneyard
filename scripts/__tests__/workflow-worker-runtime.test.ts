import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'

vi.mock('path', () => ({
  join: (...segments: string[]) => segments.filter(Boolean).join('/'),
}))

vi.mock('fs', () => ({
  existsSync: (filePath: string) => filePath.includes('/.config/codex/auth.json'),
  mkdirSync: () => {},
  writeFileSync: () => {},
  readFileSync: () => '',
}))

import {
  createWorkflowWorkerRuntime,
  type WorkflowWorkerRecord,
} from '../workflow-worker-runtime'

type SpawnCall = {
  command: string
  args: string[]
  cwd: string
  detached: boolean
  env?: NodeJS.ProcessEnv
}

type MemoryFs = {
  dirs: Set<string>
  files: Map<string, string>
  mkdirSync: (dirPath: string) => void
  writeFileSync: (filePath: string, content: string) => void
  appendFileSync: (filePath: string, content: string) => void
  readFileSync: (filePath: string) => string
  existsSync: (filePath: string) => boolean
}

function createMemoryFs(): MemoryFs {
  const dirs = new Set<string>()
  const files = new Map<string, string>()

  return {
    dirs,
    files,
    mkdirSync(dirPath) {
      dirs.add(dirPath)
    },
    writeFileSync(filePath, content) {
      files.set(filePath, content)
    },
    appendFileSync(filePath, content) {
      files.set(filePath, `${files.get(filePath) ?? ''}${content}`)
    },
    readFileSync(filePath) {
      const value = files.get(filePath)
      if (typeof value === 'undefined') {
        throw new Error(`missing file: ${filePath}`)
      }

      return value
    },
    existsSync(filePath) {
      return files.has(filePath)
    },
  }
}

function createRuntimeHarness(options: { workerDriver?: 'codex' | 'claude' } = {}) {
  const tempDir = '/virtual-output'
  const spawnCalls: SpawnCall[] = []
  const writes = new Map<number, string>()
  const alivePids = new Set<number>()
  const killed: Array<{ pid: number; signal: NodeJS.Signals | number | undefined }> = []
  const fileSystem = createMemoryFs()
  let nextPid = 41000

  const runtime = createWorkflowWorkerRuntime({
    rootDir: '/virtual-repo',
    outputDir: tempDir,
    fileSystem,
    workerDriver: options.workerDriver,
    processAdapter: {
      spawn(command, args, options) {
        const pid = nextPid++
        alivePids.add(pid)
        spawnCalls.push({
          command,
          args,
          cwd: options.cwd,
          detached: Boolean(options.detached),
          env: options.env,
        })

        return {
          pid,
          stdin: {
            write(chunk) {
              writes.set(pid, `${writes.get(pid) ?? ''}${String(chunk)}`)
            },
            end(chunk) {
              if (typeof chunk !== 'undefined') {
                writes.set(pid, `${writes.get(pid) ?? ''}${String(chunk)}`)
              }
            },
          },
          unref() {},
        }
      },
      isAlive(pid) {
        return alivePids.has(pid)
      },
      kill(pid, signal) {
        killed.push({ pid, signal })
        alivePids.delete(pid)
      },
    },
  })

  return {
    tempDir,
    runtime,
    fileSystem,
    spawnCalls,
    writes,
    alivePids,
    killed,
  }
}

describe('workflow worker runtime', () => {
  beforeEach(() => {
    vi.stubGlobal('process', {
      env: {
        HOME: '/Users/stockn',
        PATH: '/usr/bin',
        CODEX_HOME: '/Users/stockn/.codex',
        XDG_CONFIG_HOME: undefined,
      },
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  test('falls back to the default config-based CODEX_HOME when the parent environment leaves it unset', () => {
    const processStub = globalThis.process as { env: Record<string, string | undefined> }
    delete processStub.env.CODEX_HOME
    delete processStub.env.XDG_CONFIG_HOME

    const harness = createRuntimeHarness()

    harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'orchestrator',
      nickname: 'orchestrator',
      reason: 'Resume the demo workflow.',
      scope: 'demo launch',
      prompt: 'Resume the run and fan out pending work.',
    })

    expect(harness.spawnCalls[0]?.env?.CODEX_HOME).toBe('/Users/stockn/.config/codex')
  })

  test('spawns a managed worker and persists observable worker state', () => {
    const harness = createRuntimeHarness()

    const worker = harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'worker',
      nickname: 'demo-recorder-1',
      reason: 'Run the both scenario recorder pass.',
      scope: 'recorder-report.md',
      prompt: 'Execute the recorder task and update recorder-report.md.',
    })

    expect(harness.spawnCalls).toHaveLength(1)
    expect(harness.spawnCalls[0]).toMatchObject({
      command: 'codex',
      cwd: '/virtual-repo',
      detached: true,
    })
    expect(harness.spawnCalls[0]?.env).toMatchObject({
      CODEX_HOME: '/Users/stockn/.config/codex',
      HOME: '/Users/stockn',
      PATH: '/usr/bin',
    })
    expect(harness.spawnCalls[0]?.args).toContain('exec')
    expect(harness.spawnCalls[0]?.args).toContain('-C')
    expect(worker).toMatchObject({
      runId: 'demo-xvfb-20260701-200813',
      role: 'worker',
      nickname: 'demo-recorder-1',
      reason: 'Run the both scenario recorder pass.',
      scope: 'recorder-report.md',
      status: 'running',
      pid: 41000,
    })
    expect(harness.writes.get(41000)).toContain('Execute the recorder task')
    expect(harness.fileSystem.existsSync(worker.promptPath)).toBe(true)
    expect(harness.fileSystem.existsSync(worker.logPath)).toBe(true)
    expect(harness.fileSystem.existsSync(worker.lastMessagePath.replace(/\.last-message\.txt$/, '.env.json'))).toBe(true)
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('spawned demo-recorder-1')
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('worker:lifecycle')
    expect(harness.runtime.listWorkers({ activeOnly: true })).toEqual([worker])
  })

  test('spawns a worker via the claude CLI when the claude driver is selected', () => {
    const harness = createRuntimeHarness({ workerDriver: 'claude' })

    const worker = harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'planner',
      nickname: 'planner',
      reason: 'Decide the next actionable step.',
      scope: 'next-step-plan.md',
      prompt: 'Decide the single next actionable step to repair the recording loop.',
    })

    expect(harness.spawnCalls).toHaveLength(1)
    expect(harness.spawnCalls[0]).toMatchObject({
      command: 'claude',
      cwd: '/virtual-repo',
      detached: true,
    })
    expect(harness.spawnCalls[0]?.args).toEqual([
      '--agent',
      'planner',
      '--permission-mode',
      'bypassPermissions',
      '-p',
      '--',
      'Decide the single next actionable step to repair the recording loop.',
    ])
    // claude resolves the named agent's persona itself; our own code must not
    // also prepend .codex/agents/<role>.toml content into the prompt.
    expect(harness.writes.get(worker.pid)).toBeUndefined()
    expect(harness.fileSystem.readFileSync(worker.promptPath)).toBe(
      'Decide the single next actionable step to repair the recording loop.'
    )
  })

  test('stopWorker terminates the managed process and marks it stopped', () => {
    const harness = createRuntimeHarness()
    const worker = harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'worker',
      nickname: 'demo-verifier-fast',
      reason: 'Inspect current artifacts.',
      scope: 'verifier-report.md',
      prompt: 'Run a fast verification pass.',
    })

    const stopped = harness.runtime.stopWorker({
      workerId: worker.workerId,
      reason: 'Superseded by a newer verifier request.',
    })

    expect(harness.killed).toEqual([{ pid: worker.pid, signal: 'SIGTERM' }])
    expect(stopped.status).toBe('stopped')
    expect(stopped.stopReason).toBe('Superseded by a newer verifier request.')
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('stopped demo-verifier-fast')
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('"stopReason":"Superseded by a newer verifier request."')
    expect(harness.runtime.listWorkers({ activeOnly: true })).toEqual([])
  })

  test('listWorkers refreshes running workers whose processes have already exited', () => {
    const harness = createRuntimeHarness()
    const worker = harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'planner',
      nickname: 'planner-1',
      reason: 'Plan the next handoff.',
      scope: 'workflow-plan.md',
      prompt: 'Publish the next worker_request set.',
    })

    harness.alivePids.delete(worker.pid)

    const workers = harness.runtime.listWorkers()
    const refreshed = workers[0] as WorkflowWorkerRecord

    expect(refreshed.status).toBe('stopped')
    expect(refreshed.stopReason).toBe('Process exited before an explicit stop was recorded.')
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('stopped planner-1')
  })

  test('listWorkers captures the last useful log error for unexpected exits', () => {
    const harness = createRuntimeHarness()
    const worker = harness.runtime.spawnWorker({
      runId: 'demo-xvfb-20260701-200813',
      role: 'orchestrator',
      nickname: 'orchestrator',
      reason: 'Resume the demo workflow.',
      scope: 'demo launch',
      prompt: 'Resume the run and fan out pending work.',
    })

    harness.fileSystem.writeFileSync(
      worker.logPath,
      [
        'ERROR: Reconnecting... 5/5',
        'ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses',
        '',
      ].join('\n')
    )
    harness.alivePids.delete(worker.pid)

    const workers = harness.runtime.listWorkers()
    const refreshed = workers[0] as WorkflowWorkerRecord

    expect(refreshed.status).toBe('stopped')
    expect(refreshed.stopReason).toBe(
      'Process exited unexpectedly. Last log error: ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses'
    )
    expect(harness.fileSystem.readFileSync(worker.logPath)).toContain('stopped orchestrator')
  })
})
