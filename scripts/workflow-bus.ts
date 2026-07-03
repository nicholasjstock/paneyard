import * as fs from 'fs'

export type WorkflowSpawnRequestPriority = 'advisory' | 'blocking'
export type WorkflowSpawnRequestStatus = 'open' | 'fulfilled' | 'dismissed'

export type WorkflowSpawnRequest = {
  requestId: string
  runId: string
  askedBy: string
  askedAt: string
  scope: string
  text: string
  context: string | null
  requestedRole: string
  priority: WorkflowSpawnRequestPriority
  status: WorkflowSpawnRequestStatus
  fulfilledBy: string | null
  fulfilledAt: string | null
  fulfillmentNote: string | null
  tags: string[]
}

export type WorkflowBusEvent = {
  eventId: string
  at: string
  type: string
  payload: Record<string, unknown>
}

export type WorkflowRunStatus = {
  runId: string
  phase: string
  owner: string
  summary: string
  at: string
}

export type WorkflowWorkerLifecycleEvent = {
  runId: string
  owner: string
  role: string
  nickname: string
  reason: string
}

function createId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID()
  }

  return `id-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

type AppendSpawnRequestArgs = {
  runId: string
  askedBy: string
  scope: string
  text: string
  context?: string
  requestedRole: string
  priority?: WorkflowSpawnRequestPriority
  tags?: string[]
}

type FulfillSpawnRequestArgs = {
  requestId: string
  fulfilledBy: string
  fulfillmentNote: string
}

type PublishRunStatusArgs = {
  runId: string
  phase: string
  owner: string
  summary: string
}

export type WorkflowBusFileSystem = {
  existsSync(filePath: string): boolean
  mkdirSync(dir: string, options?: { recursive?: boolean }): void
  readFileSync(filePath: string, encoding: BufferEncoding): string
  writeFileSync(filePath: string, content: string): void
}

export type WorkflowBusOptions = {
  storagePath?: string
  fileSystem?: WorkflowBusFileSystem
}

function resolveDefaultStoragePath(): string {
  if (typeof process !== 'undefined' && process.env?.WORKFLOW_STATE_DIR) {
    return `${process.env.WORKFLOW_STATE_DIR.replace(/\/$/, '')}/workflow-bus.json`
  }

  const cwd = typeof process !== 'undefined' && typeof process.cwd === 'function' ? process.cwd() : '.'
  return `${cwd.replace(/\/$/, '')}/demo-output/agents-sdk/workflow-bus.json`
}

function dirname(filePath: string): string {
  const normalized = filePath.replace(/\\/g, '/')
  const index = normalized.lastIndexOf('/')
  return index >= 0 ? normalized.slice(0, index) : '.'
}

function hasStorageApi(fileSystem: WorkflowBusFileSystem): boolean {
  return (
    typeof fileSystem.existsSync === 'function' &&
    typeof fileSystem.mkdirSync === 'function' &&
    typeof fileSystem.readFileSync === 'function' &&
    typeof fileSystem.writeFileSync === 'function'
  )
}

type PublishWorkerLifecycleEventArgs = {
  runId: string
  owner: string
  role: string
  nickname: string
  reason: string
}

export type WorkflowBus = {
  publishRunStatus: (args: PublishRunStatusArgs) => WorkflowRunStatus
  appendSpawnRequest: (args: AppendSpawnRequestArgs) => WorkflowSpawnRequest
  fulfillSpawnRequest: (args: FulfillSpawnRequestArgs) => WorkflowSpawnRequest
  listRunStatuses: () => WorkflowRunStatus[]
  listOpenSpawnRequests: () => WorkflowSpawnRequest[]
  listRecentEvents: (limit?: number) => WorkflowBusEvent[]
  subscribe: (listener: (event: WorkflowBusEvent) => void) => () => void
  publishWorkerSpawned: (args: PublishWorkerLifecycleEventArgs) => WorkflowBusEvent
  publishWorkerStopped: (args: PublishWorkerLifecycleEventArgs) => WorkflowBusEvent
}

const defaultWorkflowBusFileSystem: WorkflowBusFileSystem = {
  existsSync(filePath) {
    return fs.existsSync(filePath)
  },
  mkdirSync(dir, options) {
    fs.mkdirSync(dir, options)
  },
  readFileSync(filePath, encoding) {
    return fs.readFileSync(filePath, encoding)
  },
  writeFileSync(filePath, content) {
    fs.writeFileSync(filePath, content)
  },
}

function cloneSpawnRequest(request: WorkflowSpawnRequest): WorkflowSpawnRequest {
  return {
    ...request,
    tags: [...request.tags],
  }
}

export function createWorkflowBus(options: WorkflowBusOptions = {}): WorkflowBus {
  return createPersistentWorkflowBus(options)
}

function createPersistentWorkflowBus(options: WorkflowBusOptions = {}): WorkflowBus {
  const fileSystem = options.fileSystem ?? defaultWorkflowBusFileSystem
  const storagePath = options.storagePath ?? resolveDefaultStoragePath()
  const persistent = hasStorageApi(fileSystem)
  const spawnRequests = new Map<string, WorkflowSpawnRequest>()
  const events: WorkflowBusEvent[] = []
  const runStatuses = new Map<string, WorkflowRunStatus>()
  const listeners = new Set<(event: WorkflowBusEvent) => void>()

  const loadStateFromDisk = () => {
    if (!persistent) return
    if (!fileSystem.existsSync(storagePath)) return

    try {
      const content = fileSystem.readFileSync(storagePath, 'utf8')
      const parsed = JSON.parse(content) as {
        spawnRequests?: WorkflowSpawnRequest[]
        events?: WorkflowBusEvent[]
        runStatuses?: WorkflowRunStatus[]
      }

      spawnRequests.clear()
      events.length = 0
      runStatuses.clear()

      for (const request of parsed.spawnRequests ?? []) {
        spawnRequests.set(request.requestId, {
          ...request,
          tags: [...(request.tags ?? [])],
        })
      }

      for (const event of parsed.events ?? []) {
        events.push(event)
      }

      for (const status of parsed.runStatuses ?? []) {
        runStatuses.set(status.runId, status)
      }
    } catch {
      spawnRequests.clear()
      events.length = 0
      runStatuses.clear()
    }
  }

  const persistStateToDisk = () => {
    if (!persistent) return

    const payload = {
      spawnRequests: [...spawnRequests.values()],
      events,
      runStatuses: [...runStatuses.values()],
    }

    fileSystem.mkdirSync(dirname(storagePath), { recursive: true })
    fileSystem.writeFileSync(storagePath, `${JSON.stringify(payload, null, 2)}\n`)
  }

  const emit = (type: string, payload: Record<string, unknown>) => {
    const event: WorkflowBusEvent = {
      eventId: createId(),
      at: new Date().toISOString(),
      type,
      payload,
    }

    events.push(event)
    for (const listener of listeners) listener(event)
    return event
  }

  loadStateFromDisk()

  return {
    publishRunStatus(args) {
      loadStateFromDisk()
      const status: WorkflowRunStatus = {
        runId: args.runId,
        phase: args.phase,
        owner: args.owner,
        summary: args.summary,
        at: new Date().toISOString(),
      }

      runStatuses.set(status.runId, status)
      emit('run.status', status)
      persistStateToDisk()
      return { ...status }
    },

    appendSpawnRequest(args) {
      loadStateFromDisk()
      const request: WorkflowSpawnRequest = {
        requestId: createId(),
        runId: args.runId,
        askedBy: args.askedBy,
        askedAt: new Date().toISOString(),
        scope: args.scope,
        text: args.text,
        context: args.context ?? null,
        requestedRole: args.requestedRole,
        priority: args.priority ?? 'advisory',
        status: 'open',
        fulfilledBy: null,
        fulfilledAt: null,
        fulfillmentNote: null,
        tags: [...(args.tags ?? [])],
      }

      spawnRequests.set(request.requestId, request)
      emit('spawn_request.created', {
        requestId: request.requestId,
        askedBy: request.askedBy,
        scope: request.scope,
        requestedRole: request.requestedRole,
        priority: request.priority,
        context: request.context,
        tags: request.tags,
      })
      persistStateToDisk()
      return cloneSpawnRequest(request)
    },

    fulfillSpawnRequest({ requestId, fulfilledBy, fulfillmentNote }) {
      loadStateFromDisk()
      const request = spawnRequests.get(requestId)
      if (!request) throw new Error(`Unknown spawn request: ${requestId}`)

      request.status = 'fulfilled'
      request.fulfilledBy = fulfilledBy
      request.fulfilledAt = new Date().toISOString()
      request.fulfillmentNote = fulfillmentNote
      emit('spawn_request.fulfilled', {
        requestId,
        fulfilledBy,
        fulfillmentNote,
      })
      persistStateToDisk()
      return cloneSpawnRequest(request)
    },

    publishWorkerSpawned(args) {
      loadStateFromDisk()
      const payload: WorkflowWorkerLifecycleEvent = { ...args }
      const event = emit('worker.spawned', payload)
      persistStateToDisk()
      return event
    },

    publishWorkerStopped(args) {
      loadStateFromDisk()
      const payload: WorkflowWorkerLifecycleEvent = { ...args }
      const event = emit('worker.stopped', payload)
      persistStateToDisk()
      return event
    },

    listRunStatuses() {
      loadStateFromDisk()
      return [...runStatuses.values()].map((status) => ({ ...status }))
    },

    listOpenSpawnRequests() {
      loadStateFromDisk()
      return [...spawnRequests.values()].filter((request) => request.status === 'open').map(cloneSpawnRequest)
    },

    listRecentEvents(limit = 20) {
      loadStateFromDisk()
      return events.slice(-limit)
    },

    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}

export const workflowBus = createWorkflowBus()
