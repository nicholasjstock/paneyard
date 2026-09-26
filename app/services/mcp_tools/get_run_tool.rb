module McpTools
  class GetRunTool < MCP::Tool
    tool_name "get_run"
    description "Everything known about one run in this workspace: status, its session's live state, the worktree " \
      "and branch it owns, its pull request, any publication error, and its recent timeline."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      run = AdminChatAuthorization.run!(server_context:, run_id: runId)
      return ToolResponse.error("no run #{runId} in this workspace") unless run

      ToolResponse.structured(RunPresenter.detail(run))
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
