module McpTools
  class RequestGitRemovalTool < MCP::Tool
    tool_name "request_git_removal"
    description "Ask that one path be excluded from the run's eventual commit -- for a stray file that should " \
      "never have been tracked (e.g. test-run output), not for cleaning up commit history. You cannot touch " \
      "git yourself; the path must appear in this worktree's real git status or be a tracked ignored artifact, and the committer decides " \
      "whether to honor the request when it finalizes the run."
    input_schema(
      properties: {
        runId: { type: "string" },
        path: { type: "string" },
        reason: { type: "string" }
      },
      required: %w[runId path reason]
    )

    def self.call(runId:, path:, reason:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "request_git_removal requires an authenticated worker" unless worker

      run = Run.find_by!(run_id: runId)
      request = Orchestrator::RunPublication.request_git_change!(
        run: run, requested_by_worker_id: worker.worker_id, path: path, reason: reason
      )
      ToolResponse.structured(request.as_json)
    rescue ArgumentError, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, Orchestrator::RunPublication::Error => error
      ToolResponse.error(error.message)
    end
  end
end
