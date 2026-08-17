module McpTools
  class GetProjectMemoryTool < MCP::Tool
    tool_name "get_project_memory"
    description "Read durable, evidence-backed knowledge about the target project for this run's workspace."
    input_schema(
      properties: {
        runId: { type: "string" },
        entryKeys: { type: "array", items: { type: "string" }, maxItems: 20 }
      },
      required: %w[runId]
    )

    def self.call(runId:, entryKeys: nil, server_context:)
      ToolResponse.structured(Orchestrator::ProjectMemory.snapshot(run_id: runId, entry_keys: entryKeys))
    end
  end
end
