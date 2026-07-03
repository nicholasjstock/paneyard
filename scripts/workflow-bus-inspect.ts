import * as fs from 'fs'

import { createWorkflowBus } from './workflow-bus'

type InspectArgs = {
  storagePath?: string
  limit?: number
}

export function formatWorkflowBusSnapshot(snapshot: {
  storagePath: string
  exists: boolean
  openSpawnRequests: number
  recentEvents: Array<{ type: string; at: string }>
}): string {
  const lines = [
    `Workflow bus: ${snapshot.storagePath}`,
    `Exists: ${snapshot.exists ? 'yes' : 'no'}`,
    `Open spawn requests: ${snapshot.openSpawnRequests}`,
    `Recent events: ${snapshot.recentEvents.length}`,
  ]

  for (const event of snapshot.recentEvents) {
    lines.push(`- ${event.at} ${event.type}`)
  }

  return `${lines.join('\n')}\n`
}

export function formatWorkflowBusSnapshotJson(snapshot: {
  storagePath: string
  exists: boolean
  openSpawnRequests: number
  recentEvents: Array<{ type: string; at: string }>
}): string {
  return `${JSON.stringify(snapshot, null, 2)}\n`
}

export function inspectWorkflowBus(args: InspectArgs = {}): string {
  const bus = createWorkflowBus({ storagePath: args.storagePath, fileSystem: fs })
  const storagePath = args.storagePath ?? `${process.cwd().replace(/\/$/, '')}/demo-output/agents-sdk/workflow-bus.json`
  const openSpawnRequests = bus.listOpenSpawnRequests().length
  const recentEvents = bus
    .listRecentEvents(args.limit ?? 10)
    .map((event) => ({ type: event.type, at: event.at }))

  return formatWorkflowBusSnapshot({
    storagePath,
    exists: fs.existsSync(storagePath),
    openSpawnRequests,
    recentEvents,
  })
}

export function inspectWorkflowBusJson(args: InspectArgs = {}): string {
  const bus = createWorkflowBus({ storagePath: args.storagePath, fileSystem: fs })
  const storagePath = args.storagePath ?? `${process.cwd().replace(/\/$/, '')}/demo-output/agents-sdk/workflow-bus.json`
  const openSpawnRequests = bus.listOpenSpawnRequests().length
  const recentEvents = bus
    .listRecentEvents(args.limit ?? 10)
    .map((event) => ({ type: event.type, at: event.at }))

  return formatWorkflowBusSnapshotJson({
    storagePath,
    exists: fs.existsSync(storagePath),
    openSpawnRequests,
    recentEvents,
  })
}

const isMain =
  typeof process !== 'undefined' &&
  Array.isArray(process.argv) &&
  import.meta.url === `file://${process.argv[1]}`

if (isMain) {
  const json = process.argv.includes('--json')
  const storagePath = process.argv.includes('--path')
    ? process.argv[process.argv.indexOf('--path') + 1]
    : undefined
  const limit = process.argv.includes('--limit') ? Number(process.argv[process.argv.indexOf('--limit') + 1]) : undefined

  process.stdout.write(
    json
      ? inspectWorkflowBusJson({ storagePath, limit: Number.isFinite(limit) ? limit : undefined })
      : inspectWorkflowBus({ storagePath, limit: Number.isFinite(limit) ? limit : undefined })
  )
}
