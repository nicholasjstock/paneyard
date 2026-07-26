module McpTools
  class CommitRunChangesTool < MCP::Tool
    tool_name "commit_run_changes"
    description "Commit source changes only. The committer's sanitized run-summary.md is used as the PR description, " \
      "never committed. Call list_git_change_requests first and pass excludePaths with whichever of those you " \
      "decide to honor -- Rails applies exactly that list, nothing more. Only the terminal committer worker may " \
      "call it."
    input_schema(
      properties: {
        runId: { type: "string" },
        excludePaths: { type: "array", items: { type: "string" } }
      },
      required: %w[runId]
    )

    def self.call(runId:, server_context:, excludePaths: [])
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId) || resolve_worker!(run_id: runId)
      raise ArgumentError, "commit_run_changes requires an authenticated committer worker" unless worker.role == "committer"

      run = Run.find_by!(run_id: runId)
      outcome = Orchestrator::RunPublication.commit_all!(run, exclude_paths: Array(excludePaths))
      Worker.mark_handoff_completed!(run_id: runId, role: "committer")
      ToolResponse.structured(outcome: outcome, publication_status: run.reload.publication_status)
    rescue ArgumentError, ActiveRecord::RecordNotFound, Orchestrator::RunPublication::Error => error
      ToolResponse.error(error.message)
    end

    def self.resolve_worker!(run_id:)
      Worker.active.where(run_id:, role: "committer").order(created_at: :desc).first ||
        raise(ArgumentError, "No active committer worker found")
    end
    private_class_method :resolve_worker!
  end
end
