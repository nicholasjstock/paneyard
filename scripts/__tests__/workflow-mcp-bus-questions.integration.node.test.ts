// @vitest-environment node

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'

const harnesses: WorkflowMcpTestHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.close()
  }
})

describe('workflow MCP spawn-request tools', () => {
  test('append_spawn_request stores a blocking worker request', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'append_spawn_request',
      arguments: {
        runId: 'run-1',
        askedBy: 'planner',
        scope: 'fix-summary.md',
        text: 'Need a frontend fixer.',
        requestedRole: 'worker',
        priority: 'blocking',
        tags: ['worker', 'planner-job'],
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      requestedRole: string
      priority: string
      status: string
    }
    expect(structuredContent.requestedRole).toBe('worker')
    expect(structuredContent.priority).toBe('blocking')
    expect(structuredContent.status).toBe('open')
    expect(await harness.bus.listOpenSpawnRequests()).toHaveLength(1)
  })

  test('list_open_spawn_requests excludes fulfilled requests', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const first = await harness.bus.appendSpawnRequest({
      runId: 'run-1',
      askedBy: 'planner',
      scope: 'a.md',
      text: 'First request.',
      requestedRole: 'worker',
    })
    await harness.bus.appendSpawnRequest({
      runId: 'run-1',
      askedBy: 'planner',
      scope: 'b.md',
      text: 'Second request.',
      requestedRole: 'worker',
    })
    await harness.bus.fulfillSpawnRequest({
      requestId: first.requestId,
      fulfilledBy: 'supervisor_loop',
      fulfillmentNote: 'Spawned front-fixer.',
    })

    const result = await harness.client.callTool({ name: 'list_open_spawn_requests', arguments: {} })
    const structuredContent = result.structuredContent as { requests: Array<{ scope: string }> }
    expect(structuredContent.requests.map((request) => request.scope)).toEqual(['b.md'])
  })

  test('fulfill_spawn_request marks the request fulfilled', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const request = await harness.bus.appendSpawnRequest({
      runId: 'run-1',
      askedBy: 'planner',
      scope: 'a.md',
      text: 'Need a fixer.',
      requestedRole: 'worker',
      priority: 'blocking',
    })

    const result = await harness.client.callTool({
      name: 'fulfill_spawn_request',
      arguments: {
        requestId: request.requestId,
        fulfilledBy: 'supervisor_loop',
        fulfillmentNote: 'Spawned front-fixer.',
      },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      status: string
      fulfilledBy: string
      fulfillmentNote: string
    }
    expect(structuredContent.status).toBe('fulfilled')
    expect(structuredContent.fulfilledBy).toBe('supervisor_loop')
    expect(structuredContent.fulfillmentNote).toContain('front-fixer')
  })

  test('fulfill_spawn_request surfaces an unknown requestId as isError instead of a transport rejection', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'fulfill_spawn_request',
      arguments: {
        requestId: 'does-not-exist',
        fulfilledBy: 'supervisor_loop',
        fulfillmentNote: 'n/a',
      },
    })

    expect(result.isError).toBe(true)
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(content?.text).toContain('Unknown spawn request')
  })

  test('list_recent_events respects limit and rejects out-of-range values', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.bus.publishRunStatus({ runId: 'run-1', phase: 'starting', owner: 'orchestrator', summary: 'one' })
    await harness.bus.publishRunStatus({ runId: 'run-1', phase: 'running', owner: 'orchestrator', summary: 'two' })
    await harness.bus.publishRunStatus({ runId: 'run-1', phase: 'done', owner: 'orchestrator', summary: 'three' })

    const limited = await harness.client.callTool({ name: 'list_recent_events', arguments: { limit: 2 } })
    const structuredContent = limited.structuredContent as { events: Array<{ payload: { summary: string } }> }
    expect(structuredContent.events).toHaveLength(2)
    expect(structuredContent.events.map((event) => event.payload.summary)).toEqual(['two', 'three'])

    const zero = await harness.client.callTool({ name: 'list_recent_events', arguments: { limit: 0 } })
    expect(zero.isError).toBe(true)

    const tooMany = await harness.client.callTool({ name: 'list_recent_events', arguments: { limit: 201 } })
    expect(tooMany.isError).toBe(true)
  })
})
