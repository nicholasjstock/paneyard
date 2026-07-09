module McpTools
  class ReadOrchestratorTickHistoryTool < MCP::Tool
    tool_name "read_orchestrator_tick_history"
    description "Read the recorded orchestrator tick history for a run (most recent ticks), for building a timeline view."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      ToolResponse.structured(Orchestrator::TickState.history(runId))
    end
  end
end
