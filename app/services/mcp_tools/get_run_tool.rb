module McpTools
  class GetRunTool < MCP::Tool
    tool_name "get_run"
    description "Everything known about one run: status, its session's live state, the worktree and branch it " \
      "owns, any launch error, and its checkpoint reports. Looks in the calling run's own workspace, or the " \
      "oldest registered workspace if called from outside a run; pass workspace to target a different one."
    input_schema(
      properties: {
        runId: { type: "string" },
        workspace: { type: "string", description: "Workspace name the run belongs to." }
      },
      required: %w[runId]
    )

    def self.call(runId:, server_context:, workspace: nil)
      run = WorkspaceResolution.run!(server_context:, run_id: runId, workspace:)

      ToolResponse.structured(RunPresenter.detail(run))
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
