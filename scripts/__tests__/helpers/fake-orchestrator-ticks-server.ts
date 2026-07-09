import * as http from 'http'
import type { AddressInfo } from 'net'

import type { OrchestratorDecisionState } from '../../workflow-mcp'

// Minimal in-process stand-in for the three Rails endpoints
// orchestrator-state-rails.ts talks to (Api::OrchestratorTicksController).
// Everything else the MCP tool handlers need (bus, worker runtime) is
// injected directly via WorkflowServerDeps -- this is the one piece that's
// hardwired to a real HTTP call (railsOptions.baseUrl is the only override
// point), so it's the only piece that needs an actual server in tests.
// Upsert-by-(runId, tickCount) semantics mirror the real controller.

type Tick = OrchestratorDecisionState

export type FakeOrchestratorTicksServer = {
  url: string
  close: () => Promise<void>
}

function defaultTick(runId: string): Tick {
  return {
    runId,
    phase: 'starting',
    tickCount: 0,
    lastPlanSummary: null,
    pendingSpawnKeys: [],
    followingSteps: [],
    lastStallFinding: null,
    lastUpdatedAt: null,
  }
}

function readBody(req: http.IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let raw = ''
    req.on('data', (chunk) => (raw += chunk))
    req.on('end', () => {
      try {
        resolve(raw.length > 0 ? JSON.parse(raw) : {})
      } catch (error) {
        reject(error)
      }
    })
    req.on('error', reject)
  })
}

export async function startFakeOrchestratorTicksServer(): Promise<FakeOrchestratorTicksServer> {
  const ticksByRun = new Map<string, Tick[]>()

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    res.setHeader('Content-Type', 'application/json')

    const respond = (status: number, body: unknown) => {
      res.statusCode = status
      res.end(JSON.stringify(body))
    }

    if (req.method === 'POST' && url.pathname === '/api/orchestrator_ticks') {
      readBody(req)
        .then((parsed) => {
          const body = parsed as Partial<Tick>
          const runId = body.runId as string
          const ticks = ticksByRun.get(runId) ?? []
          const existingIndex = ticks.findIndex((tick) => tick.tickCount === body.tickCount)
          const tick: Tick = {
            runId,
            phase: body.phase ?? 'starting',
            tickCount: body.tickCount ?? 0,
            lastPlanSummary: body.lastPlanSummary ?? null,
            pendingSpawnKeys: body.pendingSpawnKeys ?? [],
            followingSteps: body.followingSteps ?? [],
            lastStallFinding: body.lastStallFinding ?? null,
            lastUpdatedAt: new Date().toISOString(),
          }

          if (existingIndex >= 0) {
            ticks[existingIndex] = tick
          } else {
            ticks.push(tick)
          }
          ticks.sort((left, right) => left.tickCount - right.tickCount)
          ticksByRun.set(runId, ticks)
          respond(200, tick)
        })
        .catch(() => respond(400, { error: 'invalid JSON body' }))
      return
    }

    if (req.method === 'GET' && url.pathname === '/api/orchestrator_ticks/latest') {
      const runId = url.searchParams.get('runId') ?? ''
      const ticks = ticksByRun.get(runId) ?? []
      const latest = ticks.at(-1)
      respond(200, latest ?? defaultTick(runId))
      return
    }

    if (req.method === 'GET' && url.pathname === '/api/orchestrator_ticks/history') {
      const runId = url.searchParams.get('runId') ?? ''
      const ticks = ticksByRun.get(runId) ?? []
      respond(200, { runId, entries: ticks })
      return
    }

    respond(404, { error: `no fake route for ${req.method} ${url.pathname}` })
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()))
  const address = server.address() as AddressInfo

  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve()))),
  }
}
