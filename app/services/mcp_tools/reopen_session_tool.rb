module McpTools
  # Reopen session for an MCP client: the herdr plugin's run screen or the
  # operator's own agent. Orchestrator::SessionReopen does the work.
  #
  # Admin-only, beside close_session: bringing a closed run back is the
  # operator's decision, like ending it.
  class ReopenSessionTool < MCP::Tool
    tool_name "reopen_session"
    description "Bring back a run whose session was closed (or ended): queue it again so it gets a new session on " \
      "its own branch, resuming its agent's conversation when that is possible and otherwise starting fresh with " \
      "its task and newest report. It starts when a concurrency slot is free. Its worktree is reopened if it was " \
      "kept, or made again from its branch if it was removed; if the branch is gone too it cannot be reopened. " \
      "Only do this when the operator asks. workspace is required."
    input_schema(
      properties: {
        runId: { type: "string" },
        workspace: { type: "string", description: "Workspace name the run belongs to." }
      },
      required: %w[runId workspace]
    )

    def self.call(runId:, workspace:, server_context:)
      run = WorkspaceResolution.run!(server_context:, run_id: runId, workspace:)
      reopened = Orchestrator::SessionReopen.call(run)

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.status,
        # kept, recreated (from its branch), or new (it never had one).
        worktree: reopened.fetch(:worktree),
        branch: run.branch_name,
        queued_behind: run.workspace.runs.queued.where("created_at < ?", run.created_at).count,
        capacity: { limit: Orchestrator::RunConcurrency.limit, in_flight: Orchestrator::RunConcurrency.in_flight }
      )
    rescue Orchestrator::SessionReopen::NotReopenable => error
      ToolResponse.error(error.message, code: "not_reopenable")
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
