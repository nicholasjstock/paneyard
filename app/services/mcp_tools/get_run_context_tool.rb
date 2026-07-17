module McpTools
  class GetRunContextTool < MCP::Tool
    tool_name "get_run_context"
    description "Read the compact, curated operational context for a run: acceptance criteria, constraints, confirmed facts, rejected approaches, operator decisions, and completion blockers."
    input_schema(
      properties: {
        runId: { type: "string" },
        entryKeys: { type: "array", items: { type: "string" }, maxItems: 20 }
      },
      required: %w[runId]
    )

    def self.call(runId:, entryKeys: nil, server_context:)
      ToolResponse.structured(Orchestrator::RunContext.snapshot(run_id: runId, entry_keys: entryKeys))
    end
  end
end
