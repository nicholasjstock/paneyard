module Orchestrator
  # The operator ending a session they are finished looking at: kills the CLI,
  # closes its herdr workspace, and releases the concurrency slot. Until this
  # is called an idle session keeps both, which is deliberate -- nothing tears
  # a pane down but the operator. The worktree goes too if its work is
  # already pushed or merged; otherwise it stays for the operator to deal with.
  #
  # One place for the run screen's Close session button and the admin MCP
  # close_session tool, so the two can never disagree about what closing does.
  module SessionClose
    class NoLiveSession < StandardError; end

    module_function

    # Returns { outcome:, worktree: "removed" | "kept" | "error", error: }.
    def call(run)
      session = run.live_session
      raise NoLiveSession, "Run #{run.run_id} has no live session." if session.nil?

      outcome = session.outcome.presence || "failed"
      RunSessionRunner.finish!(session, outcome:, result: session.result)
      RunCompletion.call(run:, outcome:, summary: session.result)
      { outcome:, **release(run) }
    end

    def release(run)
      { worktree: WorktreeJanitor.release!(run) ? "removed" : "kept" }
    rescue Runner::Error => error
      { worktree: "error", error: error.message }
    end
  end
end
