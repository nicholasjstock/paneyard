#!/usr/bin/env node

import * as fs from 'node:fs'
import * as http from 'node:http'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const PKG_ROOT = path.resolve(__dirname, '..')
const UI_ROOT = path.join(PKG_ROOT, 'ui', 'mcp-state')

const HOST = process.env.MCP_STATE_UI_HOST ?? process.env.HOST ?? '127.0.0.1'
const PORT = Number(process.env.MCP_STATE_UI_PORT ?? process.env.PORT ?? '8789')
const WORKFLOW_HTTP_URL = (process.env.WORKFLOW_HTTP_URL ?? 'http://127.0.0.1:8788').replace(/\/+$/, '')

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
}

function sendJson(res: http.ServerResponse, statusCode: number, payload: unknown) {
  res.writeHead(statusCode, { 'Content-Type': CONTENT_TYPES['.json'] })
  res.end(`${JSON.stringify(payload, null, 2)}\n`)
}

function serveFile(res: http.ServerResponse, filePath: string) {
  const ext = path.extname(filePath)
  const contentType = CONTENT_TYPES[ext] ?? 'application/octet-stream'
  try {
    const contents = fs.readFileSync(filePath)
    res.writeHead(200, { 'Content-Type': contentType })
    res.end(contents)
  } catch (error) {
    sendJson(res, 404, {
      error: 'Not Found',
      path: filePath,
      detail: error instanceof Error ? error.message : String(error),
    })
  }
}

function resolveAssetPath(requestPath: string): string | null {
  const sanitized = requestPath.replace(/^\/+/, '') || 'index.html'
  const candidate = path.normalize(path.join(UI_ROOT, sanitized))
  if (!candidate.startsWith(UI_ROOT)) {
    return null
  }

  if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
    return candidate
  }

  return null
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? `${HOST}:${PORT}`}`)

  if (url.pathname === '/health') {
    sendJson(res, 200, { ok: true })
    return
  }

  if (url.pathname === '/config.json') {
    sendJson(res, 200, {
      workflowHttpUrl: WORKFLOW_HTTP_URL,
      refreshMs: 2500,
    })
    return
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    serveFile(res, path.join(UI_ROOT, 'index.html'))
    return
  }

  const assetPath = resolveAssetPath(url.pathname)
  if (assetPath) {
    serveFile(res, assetPath)
    return
  }

  sendJson(res, 404, {
    error: 'Not Found',
    path: url.pathname,
  })
})

server.listen(PORT, HOST, () => {
  process.stdout.write(`workflow-mcp-state-ui listening on http://${HOST}:${PORT}\n`)
})

process.on('SIGINT', () => {
  server.close(() => process.exit(0))
})

process.on('SIGTERM', () => {
  server.close(() => process.exit(0))
})
