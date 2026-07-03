import { describe, expect, test } from 'vitest'

import { formatWorkflowLogLine } from '../workflow-logging'

describe('workflow MCP logging', () => {
  test('formats a timestamped log line with structured details', () => {
    const line = formatWorkflowLogLine({
      timestamp: '2026-07-01T18:43:31.000Z',
      scope: 'mcp:http',
      message: 'received request',
      details: { method: 'POST', path: '/mcp', sessionId: 'abc123' },
    })

    expect(line).toContain('[workflow]')
    expect(line).toContain('2026-07-01T18:43:31.000Z')
    expect(line).toContain('mcp:http')
    expect(line).toContain('received request')
    expect(line).toContain('"method":"POST"')
    expect(line).toContain('"path":"/mcp"')
    expect(line).toContain('"sessionId":"abc123"')
  })
})
