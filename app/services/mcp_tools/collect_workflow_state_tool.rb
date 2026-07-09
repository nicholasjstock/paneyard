module McpTools
  class CollectWorkflowStateTool < MCP::Tool
    tool_name "collect_workflow_state"
    description "Inspect the managed workflow artifact directory and summarize which of this run's planner-declared artifacts exist."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      run = Run.find_or_create_for_bus!(runId)
      artifact_names = Orchestrator::Planner.list_planner_declared_artifacts(run_id: runId)
      structured = Orchestrator::ArtifactStore.collect(run.target_root, runId, artifact_names)
      ToolResponse.structured(structured)
    end
  end
end
