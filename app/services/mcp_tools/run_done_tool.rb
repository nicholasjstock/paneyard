module McpTools
  # The single completion signal. A run is over when its session says so --
  # Rails has no other reliable way to tell "the agent finished the job" from
  # "the agent is idle waiting for the operator to type something", because a
  # real interactive CLI looks identical in both cases.
  #
  # RunSessionReconcileJob is the safety net for the case where this never
  # arrives (the process died, the operator closed the pane), but only this
  # call carries a result the reviewer can read, and only this call opens the
  # pull request.
  class RunDoneTool < MCP::Tool
    tool_name "run_done"
    description "Report that this run is over and hand it back to Rails. Call it exactly once, when you have " \
      "finished the task (outcome `done`), need the operator to unblock you and cannot continue (`blocked`), or " \
      "have concluded the task cannot be done as specified (`failed`). Before calling with `done`: write " \
      "run-summary.md via write_workflow_artifact, commit, and push your branch -- Rails opens the pull request " \
      "from what you pushed, and never calls it means the run holds its concurrency slot forever."
    input_schema(
      properties: {
        runId: { type: "string" },
        outcome: { type: "string", enum: RunSession::OUTCOMES },
        summary: { type: "string", description: "What happened, in a sentence or two, for the operator." }
      },
      required: %w[runId outcome summary]
    )

    def self.call(runId:, outcome:, summary:, server_context:)
      session = SessionAuthorization.session!(server_context:, run_id: runId)
      run = Run.find_by!(run_id: runId)
      session ||= run.live_session
      raise ArgumentError, "run #{runId} has no live session" unless session

      Orchestrator::RunSessionRunner.finish!(session, outcome:, result: summary)
      Orchestrator::RunCompletion.call(run:, outcome:, summary:)

      ToolResponse.structured(run_id: runId, outcome:, status: run.reload.status)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
