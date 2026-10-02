module McpTools
  # Close session for an MCP client: the herdr plugin's close action or the
  # operator's own agent. Orchestrator::SessionClose does the work for both.
  #
  # Admin-only (AdminMcpServer), like register_workspace: ending a session is
  # the operator's decision, and a run session has no business closing
  # another one, or its own.
  class CloseSessionTool < MCP::Tool
    tool_name "close_session"
    description "Close a run's live session: quits its agent CLI, " \
      "closes its herdr workspace and frees its concurrency slot. Its worktree is removed too when its work is " \
      "already saved (clean, and merged into main or pushed); otherwise it is kept. Only do this when the " \
      "operator asks: an idle session is waiting for them, not finished. workspace is required."
    input_schema(
      properties: {
        runId: { type: "string" },
        workspace: { type: "string", description: "Workspace name the run belongs to." }
      },
      required: %w[runId workspace]
    )

    def self.call(runId:, workspace:, server_context:)
      run = WorkspaceResolution.run!(server_context:, run_id: runId, workspace:)
      closed = Orchestrator::SessionClose.call(run)

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.reload.status,
        outcome: closed.fetch(:outcome),
        worktree: closed.fetch(:worktree),
        worktree_name: run.worktree_name,
        worktree_error: closed[:error]
      )
    rescue ArgumentError, Orchestrator::SessionClose::NoLiveSession => error
      ToolResponse.error(error.message)
    end
  end
end
