import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import { spawn, type ChildProcess } from 'child_process'

import { FRONT_DIR } from '../../workflow-mcp-app'

export type LiveAgentMcpServer = {
  configPath: string
  port: number
  cleanup: () => void
}

const READY_TIMEOUT_MS = 15_000
const READY_POLL_INTERVAL_MS = 200

function pickPort(): number {
  return 20000 + Math.floor(Math.random() * 20000)
}

async function waitForServerReady(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/state`)
      if (response.ok) {
        return
      }
    } catch {
      // server not accepting connections yet
    }

    await new Promise((resolve) => setTimeout(resolve, READY_POLL_INTERVAL_MS))
  }

  throw new Error(`workflow-mcp-http server on port ${port} did not become ready within ${timeoutMs}ms`)
}

// Spawns the workflow MCP server over HTTP, pre-warmed and confirmed ready
// *before* the real `claude` subprocess ever tries to connect to it. This
// deliberately avoids the stdio transport: `claude --print` (a single
// headless turn) snapshots MCP tool availability once at session init, and
// a freshly-spawned stdio server's connection handshake does not reliably
// finish in time even though the process itself starts in ~1-1.5s — this
// was confirmed to reproduce identically with the real, unmodified root
// .mcp.json, so it is not specific to this test's isolation mechanism.
// Connecting to an already-running HTTP server has no such race.
export async function startLiveAgentMcpServer(args: { stateDir: string }): Promise<LiveAgentMcpServer> {
  const port = pickPort()
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'live-agent-mcp-config-'))
  const configPath = path.join(tempDir, 'mcp-config.json')

  const child: ChildProcess = spawn('npx', ['tsx', 'scripts/workflow-mcp-http.ts'], {
    cwd: FRONT_DIR,
    env: {
      ...process.env,
      WORKFLOW_STATE_DIR: args.stateDir,
      WORKFLOW_FAKE_WORKER_SPAWN: '1',
      MCP_PORT: String(port),
    },
    stdio: 'ignore',
  })

  const cleanup = () => {
    if (!child.killed) {
      child.kill('SIGTERM')
    }
    fs.rmSync(tempDir, { recursive: true, force: true })
  }

  try {
    await waitForServerReady(port, READY_TIMEOUT_MS)
  } catch (error) {
    cleanup()
    throw error
  }

  const config = {
    mcpServers: {
      workflow: {
        type: 'http',
        url: `http://127.0.0.1:${port}/mcp`,
      },
    },
  }

  fs.writeFileSync(configPath, JSON.stringify(config, null, 2))

  return { configPath, port, cleanup }
}
