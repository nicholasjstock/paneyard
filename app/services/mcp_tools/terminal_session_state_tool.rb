module McpTools
  class TerminalSessionStateTool < MCP::Tool
    tool_name "get_workspace_state"
    description "Read current runs, workers, questions, decisions, and chaperone state for this terminal session's workspace."
    input_schema(
      properties: { runId: { type: [ "string", "null" ] } }
    )

    def self.call(server_context:, runId: nil)
      session = server_context && TerminalSession.find_by(id: server_context[:terminal_session_id])
      workspace = session&.workspace or raise "Terminal session capability missing"
      runs = workspace.runs.order(created_at: :desc)
      runs = runs.where(run_id: runId) if runId.present?
      ToolResponse.structured(
        workspace: { id: workspace.id, name: workspace.name, rootPath: workspace.root_path },
        runs: runs.limit(10).map { |run| run_summary(run) }
      )
    end

    def self.run_summary(run)
      worker = run.workers.order(created_at: :desc).first
      decision = run.planner_decisions.order(created_at: :desc).first
      {
        runId: run.run_id, task: run.task, status: run.status, phase: run.phase,
        summary: run.phase_summary, capacityAvailableAt: run.capacity_available_at&.iso8601,
        openRequests: run.spawn_requests.open_only.count,
        openQuestions: run.user_questions.open_only.order(:asked_at).limit(5).map(&:as_diagnostic_json),
        usage: Orchestrator::RunUsage.build(run),
        latestWorker: worker&.attributes&.slice("nickname", "status", "scope", "model", "stop_reason", "started_at", "stopped_at"),
        latestPlanner: decision&.attributes&.slice("status", "model", "model_calls", "context_bytes", "error", "completed_at"),
        latestChaperone: run.chaperone_reviews.order(created_at: :desc).first&.attributes&.slice(
          "subject_type", "subject_id", "status", "action", "trigger_reason", "summary", "model",
          "tool_calls", "started_at", "completed_at", "stdout", "stderr"
        )
      }
    end
    private_class_method :run_summary
  end
end
