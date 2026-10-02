module McpTools
  # Health-check tool proving the MCP transport is wired up correctly.
  class PingTool < MCP::Tool
    description "Health-check tool, proves the MCP transport is wired up."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      MCP::Tool::Response.new([ { type: "text", text: "pong" } ])
    end
  end
end
