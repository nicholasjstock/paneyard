// Shared HTTP client for the Rails-backed bus/worker-runtime/orchestrator-
// state implementations (workflow-bus-rails.ts, workflow-worker-runtime-rails.ts,
// orchestrator-state-rails.ts). Every MCP tool call from an ephemeral
// worker/planner subprocess now makes a real network call with real
// failure modes that didn't exist with local file writes (Rails not up
// yet, a dropped connection) -- retries transient connection failures
// with backoff; a non-2xx response from Rails itself (validation error,
// 404, etc.) is NOT retried since retrying wouldn't change the outcome.

const DEFAULT_BASE_URL = process.env.WORKFLOW_RAILS_URL ?? 'http://127.0.0.1:3000'
const DEFAULT_TIMEOUT_MS = 5_000
const DEFAULT_RETRIES = 2
const RETRY_DELAY_MS = 500

export class RailsApiError extends Error {
  constructor(
    message: string,
    public readonly status?: number
  ) {
    super(message)
    this.name = 'RailsApiError'
  }
}

export type RailsApiRequestOptions = {
  baseUrl?: string
  timeoutMs?: number
  retries?: number
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// Node's fetch (undici) surfaces connection failures (ECONNREFUSED, DNS
// failures, etc.) as a TypeError with a `cause`, and an aborted request
// (our own timeout) as a DOMException/Error named "AbortError" — both mean
// "couldn't reach Rails," not "Rails responded with an error," so both are
// worth retrying.
function isTransientError(error: unknown): boolean {
  if (error instanceof Error && error.name === 'AbortError') return true
  if (error instanceof TypeError) return true
  return false
}

async function requestWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timeout)
  }
}

export async function railsRequest<T>(
  path: string,
  init: RequestInit = {},
  options: RailsApiRequestOptions = {}
): Promise<T> {
  const baseUrl = options.baseUrl ?? DEFAULT_BASE_URL
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const retries = options.retries ?? DEFAULT_RETRIES
  const url = `${baseUrl.replace(/\/$/, '')}${path}`

  let lastError: unknown
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const response = await requestWithTimeout(
        url,
        {
          ...init,
          headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...init.headers },
        },
        timeoutMs
      )

      if (!response.ok) {
        const body = await response.text().catch(() => '')
        throw new RailsApiError(
          `Rails API request failed: ${response.status} ${response.statusText} for ${path}${body ? ` — ${body}` : ''}`,
          response.status
        )
      }

      const text = await response.text()
      return (text.length > 0 ? JSON.parse(text) : undefined) as T
    } catch (error) {
      lastError = error
      if (!isTransientError(error) || attempt === retries) {
        break
      }
      await sleep(RETRY_DELAY_MS * (attempt + 1))
    }
  }

  if (lastError instanceof RailsApiError) throw lastError
  throw new RailsApiError(
    `Could not reach Rails API at ${url}: ${lastError instanceof Error ? lastError.message : String(lastError)}`
  )
}

function buildQuery(params?: Record<string, string | number | boolean | undefined>): string {
  if (!params) return ''
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) search.set(key, String(value))
  }
  const query = search.toString()
  return query.length > 0 ? `?${query}` : ''
}

export function railsGet<T>(
  path: string,
  params?: Record<string, string | number | boolean | undefined>,
  options?: RailsApiRequestOptions
): Promise<T> {
  return railsRequest<T>(`${path}${buildQuery(params)}`, { method: 'GET' }, options)
}

export function railsPost<T>(path: string, body: unknown, options?: RailsApiRequestOptions): Promise<T> {
  return railsRequest<T>(path, { method: 'POST', body: JSON.stringify(body) }, options)
}

export function railsPatch<T>(path: string, body: unknown, options?: RailsApiRequestOptions): Promise<T> {
  return railsRequest<T>(path, { method: 'PATCH', body: JSON.stringify(body) }, options)
}
