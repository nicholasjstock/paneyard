import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js'
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'

import { buildWorkflowContext, type WorkflowContext } from '../../workflow-mcp'
import { createWorkflowServer, type GuardedCommandRunner } from '../../workflow-mcp-app'
import type { WorkflowBus } from '../../workflow-bus'
import type { WorkerProcessAdapter, WorkflowWorkerRuntime } from '../../workflow-worker-runtime'
import { createFakeWorkflowBus, createFakeWorkflowWorkerRuntime } from './fake-workflow-bus'
import { startFakeOrchestratorTicksServer, type FakeOrchestratorTicksServer } from './fake-orchestrator-ticks-server'

export type WorkflowMcpTestHarness = {
  tempDir: string
  outputDir: string
  bus: WorkflowBus
  runtime: WorkflowWorkerRuntime
  context: WorkflowContext
  server: McpServer
  client: Client
  close: () => Promise<void>
}

export type CreateMcpTestHarnessOptions = {
  processAdapter?: WorkerProcessAdapter
  commandRunner?: GuardedCommandRunner
}

function buildDefaultProcessAdapter(): WorkerProcessAdapter {
  let nextPid = 70000

  return {
    spawn() {
      nextPid += 1
      return {
        pid: nextPid,
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
  }
}

export async function createMcpTestHarness(
  options: CreateMcpTestHarnessOptions = {}
): Promise<WorkflowMcpTestHarness> {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-mcp-tools-'))
  const outputDir = path.join(tempDir, 'demo-output', 'agents-sdk')

  const bus = createFakeWorkflowBus()
  const runtime = createFakeWorkflowWorkerRuntime({
    rootDir: tempDir,
    outputDir,
    processAdapter: options.processAdapter ?? buildDefaultProcessAdapter(),
  })
  const context = buildWorkflowContext({
    rootDir: tempDir,
    frontDir: tempDir,
    outputDir,
  })

  // read_orchestrator_state/write_orchestrator_state/etc are the one part
  // of the tool surface not covered by bus/workerRuntime DI above (they're
  // free functions hardwired to a real HTTP call to Rails) -- point them at
  // a throwaway in-process fake server instead via railsOptions.
  const ticksServer: FakeOrchestratorTicksServer = await startFakeOrchestratorTicksServer()

  const server = createWorkflowServer({
    bus,
    workerRuntime: runtime,
    context,
    commandRunner: options.commandRunner,
    railsOptions: { baseUrl: ticksServer.url },
  })

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const client = new Client({ name: 'workflow-test-client', version: '0.0.0' })

  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)])

  const close = async () => {
    await client.close().catch(() => {})
    await serverTransport.close().catch(() => {})
    await clientTransport.close().catch(() => {})
    await ticksServer.close().catch(() => {})
    fs.rmSync(tempDir, { recursive: true, force: true })
  }

  return { tempDir, outputDir, bus, runtime, context, server, client, close }
}
