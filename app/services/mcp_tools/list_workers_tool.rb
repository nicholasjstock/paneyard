module McpTools
  class ListWorkersTool < MCP::Tool
    tool_name "list_workers"
    description "List persisted worker records, optionally filtered by run or liveness, including the captured exit code and stop reason for failed workers."
    input_schema(
      properties: {
        runId: { type: "string" },
        activeOnly: { type: "boolean" },
        limit: { type: "integer", minimum: 1, maximum: 100 }
      },
      required: []
    )

    def self.call(server_context:, runId: nil, activeOnly: nil, limit: nil)
      scope = Worker.all
      scope = scope.where(run_id: runId) if runId.present?
      scope = scope.active if activeOnly
      # Worker prompts can be very large. Recovery planners need lifecycle
      # evidence, not a copy of every worker's launch prompt or the entire
      # run history. The newest records contain the current failure context.
      worker_limit = limit.present? ? limit.to_i.clamp(1, 100) : 10
      ToolResponse.structured({ workers: scope.order(started_at: :desc).limit(worker_limit).map(&:as_diagnostic_json) })
    end
  end
end
