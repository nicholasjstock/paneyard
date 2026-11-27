module McpTools
  # Takes a queued run out of the queue before it starts
  # (Orchestrator::RunCancel): the plugin run screen's Cancel, or the
  # operator's own agent.
  #
  # Admin-only, beside close_session: deciding a job will not be done is the
  # operator's call, and a run session has no business cancelling another
  # run's place in the queue.
  class CancelRunTool < MCP::Tool
    tool_name "cancel_run"
    description "Cancel a queued run that has not started (no session yet), for example one blocked on a " \
      "dependency that failed: it becomes stopped and never launches, and runs queued after it show as blocked. " \
      "reopen_session can queue it again. A run that has launched is refused: end its session with close_session. " \
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
      Orchestrator::RunCancel.call(run)

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.status,
        stop_reason: run.stop_reason,
        stopped_at: run.stopped_at&.iso8601
      )
    rescue Orchestrator::RunCancel::NotCancellable => error
      ToolResponse.error(error.message, code: "not_cancellable")
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
