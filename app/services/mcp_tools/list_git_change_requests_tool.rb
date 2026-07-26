module McpTools
  class ListGitChangeRequestsTool < MCP::Tool
    tool_name "list_git_change_requests"
    description "List every path a worker asked to have excluded from this run's commit, so the committer can " \
      "reconcile them before calling commit_run_changes with its own excludePaths decision. Only the terminal " \
      "committer worker may call it."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "list_git_change_requests requires an authenticated committer worker" unless worker&.role == "committer"

      run = Run.find_by!(run_id: runId)
      ToolResponse.structured(requests: run.git_change_requests.order(:created_at).map(&:as_json))
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
