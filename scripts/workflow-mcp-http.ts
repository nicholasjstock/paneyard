#!/usr/bin/env node

import { randomUUID } from 'node:crypto'
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js'
import * as fs from 'node:fs'

import { context, createWorkflowServer, workerRuntime } from './workflow-mcp-app'
import { collectWorkflowServerState, type WorkflowWorkerLog } from './workflow-state'
import { workflowBus } from './workflow-bus'
import { formatWorkflowLogLine } from './workflow-logging'
import { defaultLogFileSystem, readFullLogContent, readTailLines } from './workflow-log-reader'
import { readOrchestratorTickHistory } from './workflow-mcp'

const PORT = Number(process.env.MCP_PORT ?? '8788')
const HOST = process.env.MCP_HOST ?? '127.0.0.1'

const app = createMcpExpressApp()
const transports: Record<string, StreamableHTTPServerTransport> = {}
const eventClients = new Set<{
  id: string
  write: (chunk: string) => void
}>()

type RequestLike = {
  body?: unknown
  headers: Record<string, string | string[] | undefined>
  method?: string
  path?: string
  params: Record<string, string | undefined>
  query: Record<string, string | undefined>
  on: (event: 'close', listener: () => void) => void
}

type ResponseLike = {
  headersSent?: boolean
  setHeader: (name: string, value: string) => void
  status: (code: number) => ResponseLike
  json: (body: unknown) => void
  set: (name: string, value: string) => ResponseLike
  send: (body: string) => void
  end: () => void
  flushHeaders: () => void
  write: (chunk: string) => void
}

function logHttpEvent(message: string, details?: Record<string, unknown>) {
  console.error(
    formatWorkflowLogLine({
      timestamp: new Date().toISOString(),
      scope: 'server:http',
      message,
      details,
    })
  )
}

function setCorsHeaders(res: { setHeader: (name: string, value: string) => void }) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, MCP-Session-Id')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
}

const DEFAULT_FULL_LOG_MAX_CHARS = 300_000
const HARD_CAP_FULL_LOG_CHARS = 1_000_000

function formatSseChunk(event: { eventId: string; type: string; at: string; payload: Record<string, unknown> }): string {
  const serialized = JSON.stringify(event)
  return `id: ${event.eventId}\nevent: ${event.type}\ndata: ${serialized}\n\ndata: ${serialized}\n\n`
}

const unsubscribeBus = workflowBus.subscribe((event) => {
  const chunk = formatSseChunk(event)
  for (const client of eventClients) client.write(chunk)
})

app.post('/mcp', async (req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  try {
    const sessionIdHeader = req.headers['mcp-session-id']
    const sessionId = Array.isArray(sessionIdHeader) ? sessionIdHeader[0] : sessionIdHeader
    logHttpEvent('received request', {
      method: req.method,
      path: req.path,
      sessionId: sessionId ?? null,
      initialize: isInitializeRequest(req.body),
    })
    const existingTransport = sessionId ? transports[sessionId] : undefined

    if (!existingTransport) {
      if (sessionId || !isInitializeRequest(req.body)) {
        res.status(400).json({
          jsonrpc: '2.0',
          error: {
            code: -32000,
            message: 'Bad Request: No valid session ID provided',
          },
          id: null,
        })
        return
      }

      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (newSessionId) => {
          transports[newSessionId] = transport
        },
      })
      transport.onclose = () => {
        const activeSessionId = transport.sessionId
        if (activeSessionId) delete transports[activeSessionId]
      }

      const server = createWorkflowServer()
      await server.connect(transport)
      logHttpEvent('initialized transport', {
        sessionId: transport.sessionId ?? null,
      })

      await transport.handleRequest(req as never, res as never, req.body)
      return
    }

    await existingTransport.handleRequest(req as never, res as never, req.body)
  } catch (error) {
    console.error(
      formatWorkflowLogLine({
        timestamp: new Date().toISOString(),
        scope: 'server:http',
        message: 'error handling request',
        details: { error: error instanceof Error ? error.message : String(error) },
      })
    )
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: '2.0',
        error: {
          code: -32603,
          message: 'Internal server error',
        },
        id: null,
      })
    }
  }
})

app.get('/mcp', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  res.status(405).set('Allow', 'POST').send('Method Not Allowed')
})

app.options('/mcp', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  res.status(204).end()
})

app.get('/state', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  const state = collectWorkflowServerState({
    bus: workflowBus,
    workerRuntime,
  })
  res.json(state)
})

app.options('/state', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  res.status(204).end()
})

app.get('/workers/:workerId/log', (req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  const workerId = req.params.workerId ?? ''
  const tail = Number(req.query.tail ?? '120')
  const tailLines = Number.isFinite(tail) && tail > 0 ? Math.min(tail, 500) : 120
  const wantsFullLog = req.query.full === '1' || req.query.full === 'true'
  const maxBytes = Number(req.query.maxBytes ?? DEFAULT_FULL_LOG_MAX_CHARS)
  const maxChars =
    Number.isFinite(maxBytes) && maxBytes > 0
      ? Math.min(maxBytes, HARD_CAP_FULL_LOG_CHARS)
      : DEFAULT_FULL_LOG_MAX_CHARS
  const worker = workerRuntime.listWorkers().find((record) => record.workerId === workerId)

  if (!worker) {
    res.status(404).json({
      error: 'Worker not found',
      workerId,
    })
    return
  }

  const fullLog = wantsFullLog ? readFullLogContent(defaultLogFileSystem, worker.logPath, maxChars) : null

  const payload: WorkflowWorkerLog = {
    workerId: worker.workerId,
    runId: worker.runId,
    role: worker.role,
    nickname: worker.nickname,
    status: worker.status,
    logPath: worker.logPath,
    lastMessagePath: worker.lastMessagePath,
    startedAt: worker.startedAt,
    stoppedAt: worker.stoppedAt,
    stopReason: worker.stopReason,
    tail: readTailLines(defaultLogFileSystem, worker.logPath, tailLines),
    lastMessage: fs.existsSync(worker.lastMessagePath) ? fs.readFileSync(worker.lastMessagePath, 'utf8') : null,
    logContent: fullLog?.content ?? null,
    logTruncated: fullLog?.truncated ?? false,
    logTotalBytes: fullLog?.totalBytes ?? 0,
  }

  res.json(payload)
})

app.options('/workers/:workerId/log', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  res.status(204).end()
})

app.get('/runs/:runId/orchestrator-ticks', (req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  const history = readOrchestratorTickHistory(context, req.params.runId ?? '')
  res.json(history)
})

app.options('/runs/:runId/orchestrator-ticks', (_req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  res.status(204).end()
})

app.get('/events', (req: RequestLike, res: ResponseLike) => {
  setCorsHeaders(res)
  const clientId = randomUUID()
  logHttpEvent('event stream connected', { clientId })

  res.setHeader('Content-Type', 'text/event-stream')
  res.setHeader('Cache-Control', 'no-cache')
  res.setHeader('Connection', 'keep-alive')
  res.flushHeaders()

  const client = {
    id: clientId,
    write: (chunk: string) => res.write(chunk),
  }
  eventClients.add(client)

  const recentEvents = workflowBus.listRecentEvents(20)
  for (const event of recentEvents) {
    client.write(formatSseChunk(event))
  }

  req.on('close', () => {
    eventClients.delete(client)
    logHttpEvent('event stream disconnected', { clientId })
  })
})

const listener = app.listen(PORT, HOST, () => {
  logHttpEvent('listening', {
    url: `http://${HOST}:${PORT}/mcp`,
    eventsUrl: `http://${HOST}:${PORT}/events`,
  })
})

process.on('SIGINT', () => {
  unsubscribeBus()
  listener.close(() => process.exit(0))
})
