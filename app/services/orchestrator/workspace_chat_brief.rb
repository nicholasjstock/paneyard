module Orchestrator
  module WorkspaceChatBrief
    module_function

    def build(workspace)
      {
        workspace: { name: workspace.name, root_path: workspace.root_path },
        current_time: Time.current.iso8601,
        runs: workspace.runs.order(created_at: :desc).limit(5).map do |run|
          worker = run.workers.order(created_at: :desc).first
          {
            run_id: run.run_id, task: run.task, status: run.status, phase: run.phase,
            summary: run.phase_summary, capacity_available_at: run.capacity_available_at&.iso8601,
            latest_worker: worker&.attributes&.slice("nickname", "status", "scope", "model", "stop_reason"),
            open_questions: run.user_questions.open_only.count,
            usage: RunUsage.build(run)
          }
        end
      }
    end
  end
end
