module McpTools
  class ReadOrchestratorStateTool < MCP::Tool
    tool_name "read_orchestrator_state"
    description "Read the persisted orchestrator decision state for a run, or return the default empty state if none has been written yet."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      ToolResponse.structured(Orchestrator::TickState.latest(runId))
    end
  end
end
