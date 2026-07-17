module McpTools
  class ReadOrchestratorTickHistoryTool < MCP::Tool
    tool_name "read_orchestrator_tick_history"
    description "Read a compact recent tick timeline for one run. Request details only for a specific forensic investigation."
    input_schema(
      properties: {
        runId: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: Orchestrator::TickState::MAX_HISTORY_LIMIT },
        includeDetails: { type: "boolean" }
      },
      required: %w[runId]
    )

    def self.call(runId:, server_context:, limit: Orchestrator::TickState::DEFAULT_HISTORY_LIMIT, includeDetails: false)
      ToolResponse.structured(Orchestrator::TickState.history(runId, limit: limit, include_details: includeDetails))
    end
  end
end
