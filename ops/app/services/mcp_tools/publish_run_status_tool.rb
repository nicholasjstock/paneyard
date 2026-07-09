module McpTools
  class PublishRunStatusTool < MCP::Tool
    tool_name "publish_run_status"
    description "Publish a free-text phase/owner/summary status for a run."
    input_schema(
      properties: {
        runId: { type: "string" },
        phase: { type: "string" },
        owner: { type: "string" },
        summary: { type: "string" }
      },
      required: %w[runId phase owner summary]
    )

    def self.call(runId:, phase:, owner:, summary:, server_context:)
      run = Run.find_or_create_for_bus!(runId)
      run.publish_phase!(phase: phase, owner: owner, summary: summary)
      ToolResponse.structured(run.phase_status_json)
    end
  end
end
