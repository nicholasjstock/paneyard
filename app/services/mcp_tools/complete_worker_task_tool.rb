module McpTools
  class CompleteWorkerTaskTool < MCP::Tool
    tool_name "complete_worker_task"
    description "Mark the current worker's assigned task complete after its assigned artifact has been written -- " \
      "the reporter, curator, seeder, or demo role, at run finalization or (for reporter's plan_approval stage) " \
      "mid-run before any code exists. The demo role may pass clickPath (starting page, what to click) to report " \
      "how to see the change; this is persisted on the worker row the same way worker_turn's clickPath is."
    input_schema(properties: { runId: { type: "string" }, clickPath: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:, clickPath: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "complete_worker_task requires an authenticated reporter, curator, seeder, or demo worker" unless worker.role.in?(%w[reporter curator seeder demo])

      run = Run.find_by!(run_id: runId)
      artifact = Orchestrator::ArtifactStore.read_window(run.target_root, runId, worker.scope, offset: 0, limit: 1)
      raise ArgumentError, "Write #{worker.scope} before completing this task" if artifact[:content].blank?

      worker.update!(click_path: clickPath) if clickPath.present?
      Worker.mark_handoff_completed!(run_id: runId, role: worker.role)
      ToolResponse.structured(outcome: "completed", role: worker.role, artifact: worker.scope)
    rescue Errno::ENOENT
      ToolResponse.error("Write #{worker.scope} before completing this task")
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
