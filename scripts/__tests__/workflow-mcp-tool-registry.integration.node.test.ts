// @vitest-environment node

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'

const EXPECTED_TOOL_NAMES = [
  'spawn_worker',
  'list_workers',
  'stop_worker',
  'publish_run_status',
  'append_spawn_request',
  'list_open_spawn_requests',
  'fulfill_spawn_request',
  'list_recent_events',
  'plan_workflow_iteration',
  'publish_planner_jobs',
  'run_orchestrator_turn',
  'worker_turn',
  'planner_turn',
  'collect_workflow_state',
  'read_orchestrator_state',
  'read_orchestrator_tick_history',
  'read_workflow_artifact',
  'write_orchestrator_state',
  'write_workflow_artifact',
  'build_guarded_command',
  'run_guarded_command',
]

const harnesses: WorkflowMcpTestHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.close()
  }
})

describe('workflow MCP tool registry', () => {
  test('registers exactly the documented tool set, each with a description and schemas', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const { tools } = await harness.client.listTools()

    expect(tools.map((tool) => tool.name).sort()).toEqual([...EXPECTED_TOOL_NAMES].sort())
    expect(tools).toHaveLength(EXPECTED_TOOL_NAMES.length)

    for (const tool of tools) {
      expect(tool.description, `${tool.name} is missing a description`).toBeTruthy()
      expect(tool.inputSchema, `${tool.name} is missing an inputSchema`).toBeTruthy()
      expect(tool.inputSchema.type).toBe('object')
      expect(tool.outputSchema, `${tool.name} is missing an outputSchema`).toBeTruthy()
    }
  })

  test('each tool is independently callable through the real MCP client', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'list_open_spawn_requests',
      arguments: {},
    })

    expect(result.isError).toBeFalsy()
    expect(result.structuredContent).toEqual({ requests: [] })
  })
})
