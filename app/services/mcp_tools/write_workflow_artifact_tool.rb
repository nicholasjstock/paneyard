module McpTools
  class WriteWorkflowArtifactTool < MCP::Tool
    tool_name "write_workflow_artifact"
    description "Write one managed workflow artifact into front/demo-output/agents-sdk, scoped to the given run so concurrent runs and workers never overwrite each other's files."
    input_schema(
      properties: { runId: { type: "string" }, artifactName: { type: "string" }, content: { type: "string" } },
      required: %w[runId artifactName content]
    )

    def self.call(runId:, artifactName:, content:, server_context:)
      run = Run.find_or_create_for_bus!(runId)
      path = Orchestrator::ArtifactStore.write(run.target_root, runId, artifactName, content)
      ToolResponse.structured({ artifactName: artifactName, path: path })
    end
  end
end
