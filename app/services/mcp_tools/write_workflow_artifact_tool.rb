module McpTools
  class WriteWorkflowArtifactTool < MCP::Tool
    tool_name "write_workflow_artifact"
    description "Write one managed workflow artifact into the workspace-declared artifact directory, scoped to the run."
    input_schema(
      properties: { runId: { type: "string" }, artifactName: { type: "string" }, content: { type: "string" } },
      required: %w[runId artifactName content]
    )

    def self.call(runId:, artifactName:, content:, server_context:)
      # No assigned-artifact check any more: a session owns the whole job, so
      # it writes whatever artifacts the job needs rather than exactly the one
      # a planner named for it. Rails reads none of them back; what a session
      # has to say to the operator goes in its report_idle summary.
      SessionAuthorization.session!(server_context:, run_id: runId)
      run = Run.find_or_create_for_bus!(runId)
      path = Orchestrator::ArtifactStore.write(run.target_root, runId, artifactName, content)
      ToolResponse.structured({ artifactName: artifactName, path: path })
    end
  end
end
