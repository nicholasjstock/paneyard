module McpTools
  class ListOpenSpawnRequestsTool < MCP::Tool
    tool_name "list_open_spawn_requests"
    description "List every open spawn request across all runs."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      ToolResponse.structured({ requests: SpawnRequest.open_only.map(&:as_json) })
    end
  end
end
