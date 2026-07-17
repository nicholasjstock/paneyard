module McpTools
  class ListWorkersTool < MCP::Tool
    tool_name "list_workers"
    description "List compact worker diagnostics for one run, including the selected model, final usage, exit code, and stop reason."
    input_schema(
      properties: {
        runId: { type: "string" },
        activeOnly: { type: "boolean" },
        limit: { type: "integer", minimum: 1, maximum: 20 }
      },
      required: %w[runId]
    )

    def self.call(server_context:, runId:, activeOnly: nil, limit: nil)
      scope = Worker.where(run_id: runId)
      scope = scope.active if activeOnly
      # Worker prompts can be very large. Recovery planners need lifecycle
      # evidence, not a copy of every worker's launch prompt or the entire
      # run history. The newest records contain the current failure context.
      worker_limit = limit.present? ? limit.to_i.clamp(1, 20) : 5
      ToolResponse.structured({ workers: scope.order(started_at: :desc).limit(worker_limit).map(&:as_diagnostic_json) })
    end
  end
end
