module McpTools
  class ListWorkersTool < MCP::Tool
    tool_name "list_workers"
    description "List persisted worker records, optionally filtered by run or liveness."
    input_schema(
      properties: {
        runId: { type: "string" },
        activeOnly: { type: "boolean" }
      },
      required: []
    )

    def self.call(server_context:, runId: nil, activeOnly: nil)
      scope = Worker.all
      scope = scope.where(run_id: runId) if runId.present?
      scope = scope.active if activeOnly
      ToolResponse.structured({ workers: scope.map(&:as_json) })
    end
  end
end
