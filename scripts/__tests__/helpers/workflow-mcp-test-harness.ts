import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js'
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'

import { buildWorkflowContext, type WorkflowContext } from '../../workflow-mcp'
import { createWorkflowBus, type WorkflowBusOptions } from '../../workflow-bus'
import { createWorkflowServer, type GuardedCommandRunner } from '../../workflow-mcp-app'
import { createWorkflowWorkerRuntime, type WorkerProcessAdapter } from '../../workflow-worker-runtime'

type WorkflowBus = ReturnType<typeof createWorkflowBus>
type WorkflowWorkerRuntime = ReturnType<typeof createWorkflowWorkerRuntime>

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
  busOptions?: Partial<WorkflowBusOptions>
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

  const bus = createWorkflowBus({
    storagePath: path.join(tempDir, 'workflow-bus.json'),
    ...options.busOptions,
  })
  const runtime = createWorkflowWorkerRuntime({
    rootDir: tempDir,
    outputDir,
    processAdapter: options.processAdapter ?? buildDefaultProcessAdapter(),
  })
  const context = buildWorkflowContext({
    rootDir: tempDir,
    frontDir: tempDir,
    outputDir,
  })

  const server = createWorkflowServer({
    bus,
    workerRuntime: runtime,
    context,
    commandRunner: options.commandRunner,
  })

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const client = new Client({ name: 'workflow-test-client', version: '0.0.0' })

  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)])

  const close = async () => {
    await client.close().catch(() => {})
    await serverTransport.close().catch(() => {})
    await clientTransport.close().catch(() => {})
    fs.rmSync(tempDir, { recursive: true, force: true })
  }

  return { tempDir, outputDir, bus, runtime, context, server, client, close }
}
