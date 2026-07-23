module McpTools
  class CompleteRunFinalizationTool < MCP::Tool
    tool_name "complete_run_finalization"
    description "Mark the reporter or curator finalization stage complete after its assigned artifact has been written."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "complete_run_finalization requires an authenticated reporter or curator" unless worker.role.in?(%w[reporter curator])

      run = Run.find_by!(run_id: runId)
      artifact = Orchestrator::ArtifactStore.read_window(run.target_root, runId, worker.scope, offset: 0, limit: 1)
      raise ArgumentError, "Write #{worker.scope} before completing this stage" if artifact[:content].blank?

      Worker.mark_handoff_completed!(run_id: runId, role: worker.role)
      ToolResponse.structured(outcome: "completed", role: worker.role, artifact: worker.scope)
    rescue Errno::ENOENT
      ToolResponse.error("Write #{worker.scope} before completing this stage")
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
