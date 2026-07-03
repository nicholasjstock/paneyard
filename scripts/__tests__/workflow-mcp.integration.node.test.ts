// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js'

import { createWorkflowBus } from '../workflow-bus'
import { createWorkflowServer } from '../workflow-mcp-app'
import { createWorkflowWorkerRuntime } from '../workflow-worker-runtime'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('workflow MCP integration', () => {
  test('runs the orchestrator tool end to end and fans out planner and worker roles', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-mcp-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: {
        spawn(command, args, options) {
          return {
            pid: 60000 + args.length,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive() {
          return true
        },
        kill() {},
      },
    })

    const staleWorker = runtime.spawnWorker({
      runId: 'demo-20260702-130619',
      role: 'back_fixer',
      nickname: 'back-fixer',
      reason: 'Frontend-only defect: request CTA resolution needs a frontend route fix.',
      scope: 'fix-summary.md',
      prompt: 'Investigate the frontend blocker and report a fix summary.',
    })
    const staleTime = new Date('2026-07-02T10:00:00.000Z')
    fs.utimesSync(staleWorker.logPath, staleTime, staleTime)
    fs.writeFileSync(staleWorker.lastMessagePath, 'Waiting on the frontend route fix.\n')
    fs.utimesSync(staleWorker.lastMessagePath, staleTime, staleTime)
    fs.utimesSync(staleWorker.promptPath, staleTime, staleTime)

    const server = createWorkflowServer({
      bus,
      workerRuntime: runtime,
    })
    bus.appendSpawnRequest({
      runId: 'demo-20260702-130619',
      askedBy: 'orchestrator',
      scope: 'demo launch',
      text: 'Start the next demo handoff.',
      context: 'Need the orchestrator to fan out the next workers for the current demo run.',
      requestedRole: 'planner',
      priority: 'blocking',
      tags: ['launch', 'demo', 'orchestration'],
    })
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
    const client = new Client({ name: 'workflow-test-client', version: '0.0.0' })

    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)])

      const result = await client.callTool({
        name: 'run_orchestrator_turn',
        arguments: {
          runId: 'demo-20260702-130619',
          task: 'Repair the demo flow',
          scenario: 'both',
          frontendUrl: 'http://localhost:5174',
        },
      })

      const structuredContent = result.structuredContent as {
        plan: { steps: Array<{ owner: string; artifact: string }> }
        jobs: Array<{ step: { owner: string; artifact: string } }>
      }

      expect(structuredContent.plan.steps.map((step) => step.owner)).toEqual([
        'orchestrator',
        'demo_recorder',
        'demo_verifier',
        'front_fixer',
        'demo_recorder',
        'demo_verifier',
      ])
      expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual([
        'demo_recorder',
        'demo_verifier',
        'front_fixer',
        'demo_recorder',
        'demo_verifier',
      ])
      expect(bus.listOpenSpawnRequests().map((request) => request.requestedRole)).toEqual([
        'planner',
        'demo_recorder',
        'demo_verifier',
        'front_fixer',
        'demo_recorder',
        'demo_verifier',
      ])
      expect(runtime.listWorkers({ runId: 'demo-20260702-130619', activeOnly: true }).map((worker) => worker.role)).toEqual([
        'back_fixer',
      ])
    } finally {
      await client.close().catch(() => {})
      await serverTransport.close().catch(() => {})
      await clientTransport.close().catch(() => {})
    }
  })

  test('routes infrastructure stalls to the infra fixer through the orchestrator tool', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-mcp-'))
    tempDirs.push(tempDir)

    const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')
    const bus = createWorkflowBus({
      storagePath: path.join(tempDir, 'workflow-bus.json'),
    })
    const runtime = createWorkflowWorkerRuntime({
      rootDir: tempDir,
      outputDir,
      processAdapter: {
        spawn(command, args, options) {
          return {
            pid: 61000 + args.length,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive() {
          return true
        },
        kill() {},
      },
    })

    const staleWorker = runtime.spawnWorker({
      runId: 'demo-20260702-130620',
      role: 'front_fixer',
      nickname: 'front-fixer',
      reason:
        'Docker Playwright version mismatch: the recording image ships Playwright 1.58.2 while the project depends on Playwright 1.61.1.',
      scope: 'fix-summary.md',
      prompt: 'Investigate the infrastructure mismatch and report a fix summary.',
    })
    const staleTime = new Date('2026-07-02T10:00:00.000Z')
    fs.utimesSync(staleWorker.logPath, staleTime, staleTime)
    fs.writeFileSync(
      staleWorker.lastMessagePath,
      'The recorder is blocked by a Docker Playwright version mismatch.\n'
    )
    fs.utimesSync(staleWorker.lastMessagePath, staleTime, staleTime)
    fs.utimesSync(staleWorker.promptPath, staleTime, staleTime)

    const server = createWorkflowServer({
      bus,
      workerRuntime: runtime,
    })
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
    const client = new Client({ name: 'workflow-test-client', version: '0.0.0' })

    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)])

      const result = await client.callTool({
        name: 'run_orchestrator_turn',
        arguments: {
          runId: 'demo-20260702-130620',
          task: 'Repair the demo recording loop',
          scenario: 'both',
          frontendUrl: 'http://localhost:5174',
        },
      })

      const structuredContent = result.structuredContent as {
        plan: { steps: Array<{ owner: string; artifact: string }> }
        jobs: Array<{ step: { owner: string; artifact: string } }>
      }

      expect(structuredContent.plan.steps.map((step) => step.owner)).toEqual([
        'orchestrator',
        'demo_recorder',
        'demo_verifier',
        'infra_fixer',
        'demo_recorder',
        'demo_verifier',
      ])
      expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual([
        'demo_recorder',
        'demo_verifier',
        'infra_fixer',
        'demo_recorder',
        'demo_verifier',
      ])
      expect(bus.listOpenSpawnRequests().map((request) => request.requestedRole)).toContain('infra_fixer')
      expect(runtime.listWorkers({ runId: 'demo-20260702-130620', activeOnly: true }).map((worker) => worker.role)).toEqual([
        'front_fixer',
      ])
    } finally {
      await client.close().catch(() => {})
      await serverTransport.close().catch(() => {})
      await clientTransport.close().catch(() => {})
    }
  })
})
