module McpTools
  class ListOpenSpawnRequestsTool < MCP::Tool
    tool_name "list_open_spawn_requests"
    description "List compact open spawn requests for one run."
    input_schema(
      properties: { runId: { type: "string" }, includeDetails: { type: "boolean" } },
      required: %w[runId]
    )

    def self.call(server_context:, runId:, includeDetails: false)
      requests = SpawnRequest.open_only.where(run_id: runId)
      payload = includeDetails ? requests.map(&:as_json) : requests.map(&:as_diagnostic_json)
      ToolResponse.structured({ requests: payload })
    end
  end
end
