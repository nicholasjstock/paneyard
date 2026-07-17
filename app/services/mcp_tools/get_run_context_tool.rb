module McpTools
  class GetRunContextTool < MCP::Tool
    tool_name "get_run_context"
    description "Read the compact, curated operational context for a run: acceptance criteria, constraints, confirmed facts, rejected approaches, operator decisions, and completion blockers."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      ToolResponse.structured(Orchestrator::RunContext.snapshot(run_id: runId))
    end
  end
end
