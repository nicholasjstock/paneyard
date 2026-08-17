module McpTools
  class ReadWorkflowArtifactTool < MCP::Tool
    tool_name "read_workflow_artifact"
    description "Read a bounded window of one managed workflow artifact. Start with the default preview, then request a later offset only when more evidence is needed."
    input_schema(
      properties: {
        runId: { type: "string" },
        artifactName: { type: "string" },
        inheritFromRunId: { type: "string" },
        offset: { type: "integer", minimum: 0 },
        limit: { type: "integer", minimum: 1, maximum: Orchestrator::ArtifactStore::MAX_READ_LIMIT }
      },
      required: %w[runId artifactName]
    )

    def self.call(runId:, artifactName:, server_context:, inheritFromRunId: nil, offset: 0, limit: Orchestrator::ArtifactStore::DEFAULT_READ_LIMIT)
      run = Run.find_or_create_for_bus!(runId)
      source = inheritFromRunId.present? ? Run.find_by!(run_id: inheritFromRunId) : run.artifact_source_run(artifactName)
      unless source == run || run.available_launch_artifacts.any? { |entry| (entry["source_run_id"] || entry[:source_run_id]) == source.run_id }
        raise ArgumentError, "Artifact source run is not in this run's lineage"
      end
      window = Orchestrator::ArtifactStore.read_window(source.target_root, source.run_id, artifactName, offset: offset, limit: limit)
      ToolResponse.structured({ artifactName: artifactName, sourceRunId: source.run_id, **window })
    end
  end
end
