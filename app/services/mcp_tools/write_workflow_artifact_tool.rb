module McpTools
  class WriteWorkflowArtifactTool < MCP::Tool
    tool_name "write_workflow_artifact"
    description "Write one managed workflow artifact into the workspace-declared artifact directory, scoped to the run."
    input_schema(
      properties: { runId: { type: "string" }, artifactName: { type: "string" }, content: { type: "string" } },
      required: %w[runId artifactName content]
    )

    def self.call(runId:, artifactName:, content:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      if worker && worker.scope != artifactName
        return ToolResponse.error("artifactName must match the assigned worker artifact: #{worker.scope}")
      end
      run = Run.find_or_create_for_bus!(runId)
      path = Orchestrator::ArtifactStore.write(run.target_root, runId, artifactName, content)
      ToolResponse.structured({ artifactName: artifactName, path: path })
    end
  end
end
