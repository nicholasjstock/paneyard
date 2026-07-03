#!/usr/bin/env node

import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'

import { createWorkflowServer } from './workflow-mcp-app'
import { formatWorkflowLogLine } from './workflow-logging'

async function main() {
  const server = createWorkflowServer()
  const transport = new StdioServerTransport()
  await server.connect(transport)
  console.error(
    formatWorkflowLogLine({
      timestamp: new Date().toISOString(),
      scope: 'server:stdio',
      message: 'running on stdio',
    })
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
})
