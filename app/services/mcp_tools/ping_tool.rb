module McpTools
  # Health-check tool proving the MCP transport is wired up correctly --
  # real tools land in this directory as the port from
  # scripts/workflow-mcp-app.ts proceeds.
  class PingTool < MCP::Tool
    description "Health-check tool, proves the MCP transport is wired up."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      MCP::Tool::Response.new([ { type: "text", text: "pong" } ])
    end
  end
end
