import { describe, expect, test } from 'vitest'

import {
  formatWorkflowBusSnapshot,
  formatWorkflowBusSnapshotJson,
} from '../workflow-bus-inspect'

describe('workflow bus inspector', () => {
  test('formats a compact snapshot for terminal inspection', () => {
    const output = formatWorkflowBusSnapshot({
      storagePath: '/virtual/workflow-bus.json',
      exists: true,
      openSpawnRequests: 2,
      recentEvents: [
        { at: '2026-07-02T10:00:00.000Z', type: 'run.status' },
        { at: '2026-07-02T10:00:01.000Z', type: 'worker.spawned' },
      ],
    })

    expect(output).toContain('Workflow bus: /virtual/workflow-bus.json')
    expect(output).toContain('Exists: yes')
    expect(output).toContain('Open spawn requests: 2')
    expect(output).toContain('Recent events: 2')
    expect(output).toContain('2026-07-02T10:00:00.000Z run.status')
    expect(output).toContain('2026-07-02T10:00:01.000Z worker.spawned')
  })

  test('formats a JSON snapshot for jq piping', () => {
    const output = formatWorkflowBusSnapshotJson({
      storagePath: '/virtual/workflow-bus.json',
      exists: true,
      openSpawnRequests: 1,
      recentEvents: [{ at: '2026-07-02T10:00:02.000Z', type: 'worker.stopped' }],
    })

    expect(() => JSON.parse(output)).not.toThrow()

    const parsed = JSON.parse(output) as {
      storagePath: string
      exists: boolean
      openSpawnRequests: number
      recentEvents: Array<{ type: string; at: string }>
    }

    expect(parsed).toMatchObject({
      storagePath: '/virtual/workflow-bus.json',
      exists: true,
      openSpawnRequests: 1,
    })
    expect(parsed.recentEvents).toEqual([
      { at: '2026-07-02T10:00:02.000Z', type: 'worker.stopped' },
    ])
  })
})
