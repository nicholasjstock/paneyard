module McpTools
  class ReadWorkflowArtifactTool < MCP::Tool
    tool_name "read_workflow_artifact"
    description "Read a bounded window of one managed workflow artifact. Start with the default preview, then request a later offset only when more evidence is needed."
    input_schema(
      properties: {
        runId: { type: "string" },
        artifactName: { type: "string" },
        offset: { type: "integer", minimum: 0 },
        limit: { type: "integer", minimum: 1, maximum: Orchestrator::ArtifactStore::MAX_READ_LIMIT }
      },
      required: %w[runId artifactName]
    )

    def self.call(runId:, artifactName:, server_context:, offset: 0, limit: Orchestrator::ArtifactStore::DEFAULT_READ_LIMIT)
      run = Run.find_or_create_for_bus!(runId)
      window = Orchestrator::ArtifactStore.read_window(run.target_root, runId, artifactName, offset: offset, limit: limit)
      ToolResponse.structured({ artifactName: artifactName, **window })
    end
  end
end
