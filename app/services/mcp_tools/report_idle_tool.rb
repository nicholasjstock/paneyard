module McpTools
  # How a session tells Rails it has stopped working.
  #
  # Rails cannot infer this. A real interactive CLI looks identical whether the
  # agent has finished the job or is sitting at its prompt waiting for someone
  # to type something, so only the session itself can say which.
  #
  # This reports; it does not end the run. The pane stays open, the session
  # keeps its concurrency slot, and nothing is pushed or torn down. What
  # happens next -- send more work, close the session -- is the operator's
  # decision. JobFinishedTool provides the explicit end-of-job exception.
  #
  # The summary is the substance, not a status line: operator clients show the
  # checkpoints and not the pane, so each one has to stand on its own as a
  # report of what was done.
  #
  # A session reports more than once over a run: it goes idle, the operator
  # sends more work, it goes idle again. Each report is a checkpoint covering
  # only the interval since the previous one, so they accumulate into the run's
  # history (RunCheckpoint) instead of overwriting one another. Repeated calls
  # are the normal shape here, not a race to guard against.
  class ReportIdleTool < MCP::Tool
    tool_name "report_idle"
    description "Tell the operator you have stopped and where things stand. Call it every time you go idle: " \
      "`done` (task finished), `blocked` (you need the operator; put the question in the summary) or `failed` " \
      "(cannot be done as specified; say why). It does not end the run or close your terminal, and it is not " \
      "a cue to commit, push or merge: do each of those only when the operator asks for that one. The operator reads these reports instead of your terminal and may send more work; report " \
      "again when you next stop. Use job_finished only when explicitly asked to end the job, after completing all requested work and verifying a merge or push."
    input_schema(
      properties: {
        runId: { type: "string", description: "Optional: your own run is used by default." },
        outcome: { type: "string", enum: RunSession::OUTCOMES },
        summary: {
          type: "string",
          description: "Markdown report of the work since your previous report only -- earlier ones are " \
            "kept, so do not repeat them. What you changed and why, how you verified it (commands and " \
            "results), what failed or was skipped, what is uncommitted, committed or pushed, and how the " \
            "operator can try it, and what should happen next. For `blocked`, lead with the question."
        }
      },
      required: %w[outcome summary]
    )

    # runId is optional: the capability already says which run is calling,
    # so it only needs checking when given (SessionAuthorization rejects a
    # mismatch). Still accepted so a session briefed to pass it keeps working.
    def self.call(outcome:, summary:, server_context:, runId: nil)
      session = SessionAuthorization.session!(server_context:, run_id: runId)
      run = session&.run || Run.find_by!(run_id: runId.presence || raise(ArgumentError, "runId is required"))
      session ||= run.live_session
      raise ArgumentError, "run #{run.run_id} has no live session" unless session

      Orchestrator::RunIdleReport.call(run:, session:, outcome:, summary:)

      ToolResponse.structured(run_id: run.run_id, outcome:, status: run.reload.status)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
