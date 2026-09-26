module McpTools
  # How a session tells Rails it has stopped working.
  #
  # Rails cannot infer this. A real interactive CLI looks identical whether the
  # agent has finished the job or is sitting at its prompt waiting for someone
  # to type something, so only the session itself can say which.
  #
  # This reports; it does not end the run. The pane stays open, the session
  # keeps its concurrency slot, and nothing is pushed, published, or torn down.
  # What happens next -- open a pull request, send more work, close the session
  # -- is the operator's decision, made after looking at this pane. That is the
  # whole point: the previous tool ended the run and opened a pull request in
  # the same call, which left nothing to look at and no decision to make.
  #
  # A session reports more than once over a run: it goes idle, the operator
  # sends more work, it goes idle again. Each report is a checkpoint covering
  # only the interval since the previous one, so they accumulate into the run's
  # history (RunCheckpoint) instead of overwriting one another. Repeated calls
  # are the normal shape here, not a race to guard against.
  class ReportIdleTool < MCP::Tool
    tool_name "report_idle"
    description "Report that you have stopped working and say where the run stands. Call it every time you " \
      "go idle: when you have finished the task (outcome `done`), need the operator and cannot continue " \
      "(`blocked`), or have concluded the task cannot be done as specified (`failed`). Before reporting " \
      "`done`: write run-summary.md via write_workflow_artifact, commit, and push your branch. This does " \
      "NOT end the run and does NOT open a pull request -- the operator reads this pane and decides what " \
      "happens next, and may well send you more work; when you go idle after that, report again. Each " \
      "report is a checkpoint covering only the interval since your previous one, and they are kept as the " \
      "run's history, so do not restate earlier reports: say what you attempted in this slice of work, " \
      "what landed, what failed, what state you are leaving behind, and what you think should happen next. " \
      "Not calling it is the one real failure: until you do, Rails cannot tell you are idle rather than " \
      "still working."
    input_schema(
      properties: {
        runId: { type: "string" },
        outcome: { type: "string", enum: RunSession::OUTCOMES },
        summary: { type: "string", description: "Where the run stands, in a sentence or two, for the operator." }
      },
      required: %w[runId outcome summary]
    )

    def self.call(runId:, outcome:, summary:, server_context:)
      session = SessionAuthorization.session!(server_context:, run_id: runId)
      run = Run.find_by!(run_id: runId)
      session ||= run.live_session
      raise ArgumentError, "run #{runId} has no live session" unless session

      Orchestrator::RunIdleReport.call(run:, session:, outcome:, summary:)

      ToolResponse.structured(run_id: runId, outcome:, status: run.reload.status)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
