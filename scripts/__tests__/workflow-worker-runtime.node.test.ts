// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'
import { createNodeWorkerProcessAdapter } from '../workflow-worker-runtime-node'

function withEnv<T>(entries: Record<string, string | undefined>, callback: () => Promise<T>): Promise<T> {
  const previous = new Map<string, string | undefined>()

  for (const [key, value] of Object.entries(entries)) {
    previous.set(key, process.env[key])
    if (typeof value === 'undefined') {
      delete process.env[key]
    } else {
      process.env[key] = value
    }
  }

  return callback().finally(() => {
    for (const [key, value] of previous.entries()) {
      if (typeof value === 'undefined') {
        delete process.env[key]
      } else {
        process.env[key] = value
      }
    }
  })
}

async function waitForFile(filePath: string, timeoutMs = 5000): Promise<void> {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (fs.existsSync(filePath)) {
      return
    }

    await new Promise((resolve) => setTimeout(resolve, 50))
  }

  throw new Error(`Timed out waiting for file: ${filePath}`)
}

async function waitForWorkerStatus(
  getStatus: () => string | undefined,
  expectedStatus: string,
  timeoutMs = 5000
): Promise<void> {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (getStatus() === expectedStatus) {
      return
    }

    await new Promise((resolve) => setTimeout(resolve, 50))
  }

  throw new Error(`Timed out waiting for worker status: ${expectedStatus}`)
}

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('workflow worker runtime process integration', () => {
  test('creates a running worker record when codex is spawned', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-worker-runtime-'))
    tempDirs.push(tempDir)

    const binDir = path.join(tempDir, 'bin')
    const outputDir = path.join(tempDir, 'output')
    const envCapturePath = path.join(tempDir, 'child-env.json')
    const promptCapturePath = path.join(tempDir, 'child-prompt.txt')
    const fakeHome = path.join(tempDir, 'home')
    const authBearingCodexHome = path.join(fakeHome, '.config', 'codex')
    fs.mkdirSync(binDir, { recursive: true })
    fs.mkdirSync(authBearingCodexHome, { recursive: true })
    fs.writeFileSync(
      path.join(authBearingCodexHome, 'auth.json'),
      JSON.stringify({
        auth_mode: 'chatgpt',
        OPENAI_API_KEY: null,
        tokens: {
          access_token: 'sk-test-from-auth-file',
          refresh_token: 'refresh-token',
          id_token: 'id-token',
          account_id: 'account-id',
        },
      })
    )

    fs.writeFileSync(
      path.join(binDir, 'codex'),
      `#!/usr/bin/env node
const fs = require('fs')
fs.writeFileSync(process.env.FAKE_CODEX_ENV_CAPTURE_PATH, JSON.stringify(process.env, null, 2))
fs.writeFileSync(process.env.FAKE_CODEX_PROMPT_CAPTURE_PATH, fs.readFileSync(0, 'utf8'))
setInterval(() => {}, 1000)
`,
      { mode: 0o755 }
    )

    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: createNodeWorkerProcessAdapter(),
    })

    await withEnv(
      {
        CODEX_HOME: path.join(tempDir, 'stale-codex-home'),
        HOME: fakeHome,
        PATH: `${binDir}:${process.env.PATH ?? ''}`,
        FAKE_CODEX_ENV_CAPTURE_PATH: envCapturePath,
        FAKE_CODEX_PROMPT_CAPTURE_PATH: promptCapturePath,
      },
      async () => {
        const worker = runtime.spawnWorker({
          runId: 'demo-xvfb-20260701-200813',
          role: 'orchestrator',
          nickname: 'orchestrator',
          reason: 'Launch orchestration with the usable auth store.',
          scope: 'demo launch',
          prompt: 'Start the run.',
        })

        await waitForFile(envCapturePath)
        await waitForFile(promptCapturePath)

        const workers = runtime.listWorkers({ runId: worker.runId, activeOnly: true })
        expect(workers).toHaveLength(1)
        expect(workers[0]).toMatchObject({
          workerId: worker.workerId,
          runId: worker.runId,
          role: 'orchestrator',
          nickname: 'orchestrator',
          status: 'running',
        })

        const childEnv = JSON.parse(fs.readFileSync(envCapturePath, 'utf8')) as Record<string, string | undefined>
        expect(childEnv.CODEX_HOME).toBe(authBearingCodexHome)
        expect(childEnv.OPENAI_API_KEY).toBe('sk-test-from-auth-file')

        await runtime.stopWorker({
          workerId: worker.workerId,
          reason: 'Clean up test worker.',
        })

        await waitForWorkerStatus(
          () => runtime.listWorkers({ runId: worker.runId })[0]?.status,
          'stopped'
        )
      }
    )
  })
})
