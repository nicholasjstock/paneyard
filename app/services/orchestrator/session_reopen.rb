module Orchestrator
  # The operator bringing a run back after its session was closed -- most
  # often the wrong one. Close session (SessionClose) kills the CLI and closes
  # its herdr workspace, but the run's branch survives, and so does its
  # worktree unless its work was already saved (WorktreeJanitor.release!).
  # Reopening gives the run a new session on that same branch.
  #
  # A reopened run is queued again, exactly like a new one: RunDispatchJob
  # starts it when a concurrency slot is free, and StartRunSessionJob hands
  # RunSessionRunner.start! the previous session. So reopening never takes a
  # slot the cap has not got, and needs no slot to be free to ask. The queue
  # is ordered by when runs were first queued, so a reopened run starts ahead
  # of anything queued after it did.
  #
  # Where the session runs:
  #   * the worktree was kept: herdr reopens it (the reuse path in
  #     GitWorktree.provision!);
  #   * it was removed, the branch is still there: herdr makes a worktree on
  #     that branch as it is (Runner::Worktrees.provision!), normally at the
  #     same path, since herdr names it after the branch;
  #   * the branch is gone too: there is nothing to reopen, and this refuses.
  #
  # What it starts with (launch_plan): the previous session's CLI
  # conversation, resumed, when its id is known and the worktree is where that
  # conversation ran (claude keys stored conversations by directory, and codex
  # resumes in the directory it started in); otherwise, or when the resumed
  # CLI will not come up, a fresh conversation whose prompt carries the task
  # and the newest report (RunPrompt.compose_reopened).
  module SessionReopen
    class NotReopenable < StandardError; end

    module_function

    # Returns { worktree: "kept" | "recreated" | "new" }, "new" being a run
    # that never got a worktree (its launch failed), which starts as it would
    # have the first time. Raises NotReopenable with what to do instead.
    def call(run)
      worktree = check!(run)
      reopened = Run.where(id: run.id, status: run.status).where.not(id: RunSession.live.select(:run_id))
        .update_all(status: "queued", stopped_at: nil, launch_error: nil, updated_at: Time.current)
      raise NotReopenable, "Run #{run.run_id} changed while it was being reopened; look at it again." unless reopened == 1

      run.reload
      RunDispatchJob.perform_later
      { worktree: }
    end

    # Why the run cannot be reopened, or nil when it can. For showing the
    # option, not for deciding: call re-checks.
    def problem(run)
      check!(run)
      nil
    rescue NotReopenable => error
      error.message
    end

    # Which worktree the reopened session would get; raises NotReopenable.
    def check!(run)
      if run.live_session
        raise NotReopenable, "Run #{run.run_id} still has a live session; there is nothing to reopen."
      end
      if run.status.in?(Run::SESSION_ACTIVE_STATUSES)
        raise NotReopenable, "Run #{run.run_id} is already #{run.status}."
      end

      runner = Runner.for(run.workspace)
      return new_worktree(run, runner) if run.branch_name.blank?

      repository = WorktreeJanitor.repository_for(run)
      if run.managed_worktree? && run.target_root.present? &&
          runner.worktree_registered?(repository_path: repository, path: run.target_root)
        return "kept"
      end
      unless runner.branch_exists?(repository_path: repository, branch: run.branch_name)
        raise NotReopenable, "Run #{run.run_id}'s worktree was removed and its branch `#{run.branch_name}` no longer " \
          "exists in #{repository}, so there is no work left to reopen it on. Queue a new run instead."
      end
      "recreated"
    rescue Runner::Error => error
      raise NotReopenable, "Could not check run #{run.run_id}'s worktree and branch: #{error.message}"
    end

    # A run whose launch failed before it had a branch starts from its base
    # branch, which has to still be there.
    def new_worktree(run, runner)
      problem = runner.base_branch_problem(repository_path: run.workspace.repository_path, branch: run.base_branch)
      raise NotReopenable, "Run #{run.run_id} never got a worktree, and its base branch cannot start one: #{problem.fetch('message')}" if problem

      "new"
    end

    # What the reopened run's new session starts with, once its worktree is
    # provisioned (so run.target_root is where it now is): { prompt: the fresh
    # session's, resume: { session_id:, prompt: } or nil }. The fresh prompt
    # is always there, for RunSessionRunner to fall back on when the resumed
    # CLI does not come up.
    def launch_plan(run, previous:, previous_root:)
      fresh = RunPrompt.compose_reopened(run:, session_driver: run.launcher_variant)
      resumable = previous.cli_session_id.present? && previous.driver == run.launcher_variant &&
        previous_root.present? && previous_root == run.target_root
      resume = { session_id: previous.cli_session_id, prompt: RunPrompt.compose_resumed(run:) } if resumable
      { prompt: fresh, resume: }
    end
  end
end
