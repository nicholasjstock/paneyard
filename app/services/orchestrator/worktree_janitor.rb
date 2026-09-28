module Orchestrator
  # Reclaims run worktrees -- the only automatic removal in the system.
  #
  # The rule is whether the work is saved elsewhere, not how old it is.
  # Removing a worktree never deletes its branch, so once the session is over
  # and the worktree is clean with HEAD already on main or pushed, it holds
  # nothing that is not somewhere else too and goes straight away -- on close
  # (release!) or on the next sweep. Anything else is kept indefinitely and
  # shown as a kept worktree (Run#kept_worktree?) until the operator pushes,
  # merges, or removes it.
  #
  # This is the orchestrator's half: which worktrees belong to a session that
  # is not over yet. Whether a worktree's work is saved, and never touching
  # `main` or a dirty worktree, is the runner's (Runner::Local's worktree
  # methods), since only its machine has the git to ask.
  module WorktreeJanitor
    class Error < StandardError; end
    module_function

    def sweep_all
      Workspace.find_each.select { |workspace| Sandbox.allows_path?(workspace.root_path) }.sum { |workspace| sweep(workspace) }
    end

    # Returns the number of worktrees removed.
    def sweep(workspace)
      Runner.for(workspace).reclaim_worktrees(source_root: workspace.source_root, keep: in_use(workspace))
    rescue Runner::Error => error
      Rails.logger.warn("WorktreeJanitor: #{workspace.name}: #{error.message}")
      0
    end

    # The worktrees a run is still working in (see Run#session_over?). A
    # worktree no run owns is an orphan and goes on the same terms as one
    # whose session is over.
    def in_use(workspace)
      runs = workspace.runs.where.not(target_root: [ nil, "" ])
      runs.where(status: Run::SESSION_ACTIVE_STATUSES)
        .or(runs.where(id: RunSession.live.select(:run_id)))
        .pluck(:target_root)
    end

    # The explicit per-run removal behind the run screen's button. `force`
    # here is the operator's own decision about their own uncommitted work.
    def remove_for_run!(run, force: false)
      raise Error, "Run #{run.run_id} has no managed worktree" if run.worktree_name.blank? || run.source_root.blank?

      Runner.for(run.workspace).remove_worktree(source_root: run.source_root, path: run.target_root, force:)
      run
    end

    # Closing a session is the operator saying they are done with it --
    # whether by Close session on the run screen or by closing the run's herdr
    # workspace by hand, which RunSessionReconcileJob picks up. Both call this.
    # Removes the worktree when nothing in it would be lost, and returns
    # whether it did.
    def release!(run)
      return false if run.worktree_name.blank? || run.source_root.blank? || run.target_root.blank?

      Runner.for(run.workspace).release_worktree(source_root: run.source_root, path: run.target_root)
    end
  end
end
