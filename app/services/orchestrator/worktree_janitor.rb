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

    # Returns the number of worktrees removed.
    def sweep(workspace)
      worktrees = finished(workspace).map { |run| { "path" => run.target_root, "base_branch" => run.base_branch } }
      return 0 if worktrees.empty?

      Runner.for(workspace).reclaim_worktrees(repository_path: workspace.repository_path, worktrees:)
    rescue Runner::Error => error
      Rails.logger.warn("WorktreeJanitor: #{workspace.name}: #{error.message}")
      0
    end

    # The workspace's runs with a worktree of their own whose session is over
    # (Run#session_over?). The runner skips any that is already gone.
    def finished(workspace)
      runs = workspace.runs.where.not(worktree_name: [ nil, "" ]).where.not(target_root: [ nil, "", workspace.repository_path ])
      runs.where.not(status: Run::SESSION_ACTIVE_STATUSES).where.not(id: RunSession.live.select(:run_id))
    end

    # The explicit per-run removal behind the run screen's button. `force`
    # here is the operator's own decision about their own uncommitted work.
    def remove_for_run!(run, force: false)
      raise Error, "Run #{run.run_id} has no managed worktree" if run.worktree_name.blank? || run.target_root.blank?

      Runner.for(run.workspace).remove_worktree(repository_path: repository_for(run), path: run.target_root, force:)
      run
    end

    # Closing a session is the operator saying they are done with it --
    # whether by Close session on the run screen or by closing the run's herdr
    # workspace by hand, which RunSessionReconcileJob picks up. Both call this.
    # Removes the worktree when nothing in it would be lost, and returns
    # whether it did.
    def release!(run)
      return false if run.worktree_name.blank? || run.target_root.blank?

      Runner.for(run.workspace).release_worktree(repository_path: repository_for(run), path: run.target_root, base_branch: run.base_branch)
    end

    # The repository the run's worktree was made from, as recorded then.
    def repository_for(run)
      run.source_root.presence || run.workspace.repository_path
    end
  end
end
