module Orchestrator
  # Reclaims run worktrees -- the only automatic removal in the system.
  #
  # The rule is whether the work is saved elsewhere, not how old it is.
  # Removing a worktree never deletes its branch, so once the session is over
  # and the worktree is clean with HEAD already in the run's own base branch
  # (the branch it started from and merges back into) or pushed, it holds
  # nothing that is not somewhere else too and goes straight away -- on close
  # (release!) or on the next sweep. Anything else is kept indefinitely and
  # shown as a kept worktree (Run#kept_worktree?) until the operator pushes,
  # merges, or removes it.
  #
  # Only Paneyard's own run worktrees are ever considered: a sweep asks about
  # the worktrees its runs recorded and nothing else, so a worktree the
  # operator (or anything else) added to the same repository is never
  # touched, and nor is the repository's own checkout.
  #
  # This is the orchestrator's half: which worktrees are a run's, and whether
  # its session is over. Whether a worktree's work is saved, and removing it
  # (through herdr), is the runner's.
  module WorktreeJanitor
    class Error < StandardError; end
    module_function

    def sweep_all
      Workspace.find_each.select { |workspace| Sandbox.allows_path?(workspace.repository_path) }.sum { |workspace| sweep(workspace) }
    end

    # Returns the number of worktrees removed. Each runner is handed only its
    # own runs' worktrees, in its own checkout of the repository.
    def sweep(workspace)
      finished(workspace).includes(:runner).group_by(&:runner).sum do |runner, runs|
        worktrees = runs.map { |run| { "path" => run.target_root, "base_branch" => run.base_branch } }
        Runner.for(runner).reclaim_worktrees(repository_path: workspace.repository_path_for(runner), worktrees:)
      rescue Runner::Error => error
        Rails.logger.warn("WorktreeJanitor: #{workspace.name} on #{runner.name}: #{error.message}")
        0
      end
    end

    # The workspace's runs with a worktree of their own whose session is over
    # (Run#session_over?), never a runner's checkout of the repository itself.
    # The runner skips any that is already gone.
    def finished(workspace)
      checkouts = [ workspace.repository_path, *workspace.checkouts.pluck(:repository_path) ].uniq
      runs = workspace.runs.where.not(worktree_name: [ nil, "" ]).where.not(target_root: [ nil, "", *checkouts ])
      runs.where.not(status: Run::SESSION_ACTIVE_STATUSES).where.not(id: RunSession.live.select(:run_id))
    end

    # Explicit per-run removal for operator clients. `force`
    # here is the operator's own decision about their own uncommitted work.
    def remove_for_run!(run, force: false)
      raise Error, "Run #{run.run_id} has no managed worktree" if run.worktree_name.blank? || run.target_root.blank?

      Runner.for(run).remove_worktree(repository_path: repository_for(run), path: run.target_root, force:)
      run
    end

    # Closing a session is the operator saying they are done with it --
    # whether by the close action or by closing the run's herdr
    # workspace by hand, which RunSessionReconcileJob picks up. Both call this.
    # Removes the worktree when nothing in it would be lost, and returns
    # whether it did.
    # Explicit finalization also verifies the run branch at its actual push
    # destination, allowing removal even without cached remote-tracking refs.
    def release!(run, finalizing: false)
      return false if run.worktree_name.blank? || run.target_root.blank?

      options = { repository_path: repository_for(run), path: run.target_root, base_branch: run.base_branch }
      options[:branch] = run.branch_name if finalizing
      Runner.for(run).release_worktree(**options)
    end

    # The repository the run's worktree was made from, as recorded then.
    def repository_for(run)
      run.source_root.presence || run.repository_path
    end
  end
end
