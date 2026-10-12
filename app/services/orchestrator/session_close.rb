module Orchestrator
  # The operator ending a session they are finished looking at: kills the CLI,
  # closes its herdr workspace, and releases the concurrency slot. Until this
  # is called an idle session keeps both. JobFinalization also uses this path
  # after explicitly requested finalization with a verified merge or push. The worktree goes too if its work is
  # already pushed or merged; otherwise it stays for the operator to deal with.
  #
  # One place for the Herdr close action and the admin MCP close_session tool.
  module SessionClose
    class NoLiveSession < StandardError; end

    module_function

    # Returns { outcome:, worktree: "removed" | "kept" | "error", error: }.
    def call(run, strict_workspace: false, finalizing: false)
      session = run.live_session
      raise NoLiveSession, "Run #{run.run_id} has no live session." if session.nil?

      outcome = session.outcome.presence || "failed"
      workspace_id = session.herdr_workspace_id
      RunSessionRunner.finish!(session, outcome:, result: session.result, close_workspace: false)
      RunCompletion.call(run:, outcome:, summary: session.result)
      released = release(run, finalizing:)
      # Removing the worktree closed its workspace; a kept one is still open.
      if workspace_id.present? && released[:worktree] != "removed"
        runner = Runner.for(run.workspace)
        strict_workspace ? runner.close_workspace!(workspace_id) : runner.close_workspace(workspace_id)
      end
      { outcome:, **released }
    end

    def release(run, finalizing: false)
      { worktree: (finalizing ? WorktreeJanitor.release!(run, finalizing: true) : WorktreeJanitor.release!(run)) ? "removed" : "kept" }
    rescue Runner::Error => error
      { worktree: "error", error: error.message }
    end
  end
end
