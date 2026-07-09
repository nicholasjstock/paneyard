module McpTools
  class ReadWorkflowArtifactTool < MCP::Tool
    tool_name "read_workflow_artifact"
    description "Read one managed workflow artifact from front/demo-output/agents-sdk, scoped to the given run so concurrent runs never read each other's files."
    input_schema(
      properties: { runId: { type: "string" }, artifactName: { type: "string" } },
      required: %w[runId artifactName]
    )

    def self.call(runId:, artifactName:, server_context:)
      run = Run.find_or_create_for_bus!(runId)
      content = Orchestrator::ArtifactStore.read(run.target_root, runId, artifactName)
      ToolResponse.structured({ artifactName: artifactName, content: content })
    end
  end
end
