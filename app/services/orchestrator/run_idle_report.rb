module Orchestrator
  # A session reporting that it has stopped working, and nothing more.
  #
  # Deliberately separate from RunCompletion: that module owns a run's terminal
  # state, and going idle is not terminal. The session stays live -- pane open,
  # process up, concurrency slot still held -- because the operator is expected
  # to read the pane and decide what happens next. Nothing here pushes,
  # publishes, kills a process, or closes a herdr workspace.
  #
  # Each call is a checkpoint covering the interval since the previous one, so
  # the reports accumulate rather than replace each other:
  #
  #   idle -> work -> report_idle -> more work -> report_idle -> ...
  #
  # The RunCheckpoint rows are the run's history and the newest is its current
  # state. The session's own outcome/result mirror that newest row so anything
  # asking "where is this run now" does not have to sort history first.
  module RunIdleReport
    module_function

    # The session status that matches each reported outcome. None of them set
    # ended_at, which is what keeps the session live and its slot held.
    STATUS_FOR_OUTCOME = { "done" => "done", "blocked" => "blocked", "failed" => "failed" }.freeze

    def call(run:, session:, outcome:, summary: nil)
      status = STATUS_FOR_OUTCOME.fetch(outcome) { raise ArgumentError, "unknown run outcome: #{outcome.inspect}" }

      checkpoint = nil
      run.with_lock do
        checkpoint = run.checkpoints.create!(run_session: session, outcome:, summary:)
        session.update!(status:, outcome:, result: summary, last_seen_at: Time.current)
        # Non-terminal: it means "a human needs to look at this", which is
        # exactly the state a run is in once its session goes idle. The run
        # becomes terminal only when the operator publishes and that PR merges,
        # or when they stop the run outright.
        run.update!(status: "awaiting_review") if run.active?
      end

      Runner.for(run.workspace).notify(
        title: "Run #{run.run_id} idle (#{outcome})",
        body: summary.to_s.truncate(140),
        sound: outcome == "done" ? "done" : "request"
      )
      checkpoint
    end
  end
end
