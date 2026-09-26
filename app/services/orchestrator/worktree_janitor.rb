require "open3"

module Orchestrator
  # Reclaims run worktrees.
  #
  # Before this existed the only removal in the system was the post-merge one
  # in RunPublication.cleanup_merged_run!, so every stopped, failed, or
  # abandoned run left its worktree on disk forever -- a real and growing mess
  # given every run gets one.
  #
  # Two rules make this safe to run unattended:
  #
  #   * never `main`. The source checkout is where every worktree's real .git
  #     lives; removing it would take the whole workspace with it.
  #   * never a dirty worktree. Uncommitted work in a failed run is exactly
  #     the work an operator is most likely to want back, so a dirty worktree
  #     is reported for a human decision rather than reclaimed. `--force` is
  #     reserved for the explicit per-run button.
  #
  # Removing a worktree never deletes its branch. Once the session is closed
  # and the branch is already on main or pushed, the worktree holds nothing
  # that is not somewhere else too, so it goes straight away -- on close
  # (release!) or on the next sweep. RETENTION only still applies to a
  # finished run whose commits exist nowhere but its local branch.
  module WorktreeJanitor
    class Error < StandardError; end
    module_function

    # How long a run must have been terminal before its worktree is reclaimed.
    # Long enough that "the run failed, let me go look at what it did" is
    # still possible the next morning.
    RETENTION = 24.hours

    def sweep_all(now: Time.current)
      Workspace.find_each.sum { |workspace| sweep(workspace, now:) }
    end

    # Returns the number of worktrees removed.
    def sweep(workspace, now: Time.current)
      source_root = Pathname(workspace.source_root)
      return 0 unless source_root.directory?

      removed = 0
      entries(source_root).each do |path|
        next if protected_path?(source_root, path)

        run = run_for(workspace, path)
        next unless reclaimable?(run, path:, now:)
        next if dirty?(path)

        remove_worktree!(source_root, path)
        removed += 1
      end
      # Also reaps entries whose directory an operator deleted by hand, which
      # git otherwise keeps listing as "prunable" forever.
      prune!(source_root)
      removed
    rescue Error => error
      Rails.logger.warn("WorktreeJanitor: #{workspace.name}: #{error.message}")
      removed || 0
    end

    # A worktree with no Run row at all is an orphan -- a run whose record was
    # destroyed, or a leftover from an earlier version of this tool -- and is
    # reclaimable on the same terms as a terminal run.
    def reclaimable?(run, path:, now:)
      return true if run.nil?
      return false if run.status.in?(%w[queued launching running]) || run.live_session
      return true if work_saved?(path)
      return false if run.active?

      terminal_at = run.stopped_at || run.updated_at
      terminal_at.present? && terminal_at <= now - RETENTION
    end

    def entries(source_root)
      git!(source_root, "worktree", "list", "--porcelain")
        .split("\n")
        .filter_map { |line| Pathname(line.delete_prefix("worktree ")) if line.start_with?("worktree ") }
    end

    # `git worktree list` reports every path with its symlinks resolved, while
    # a Run's target_root is whatever string provisioned it. Those two are not
    # interchangeable: anywhere a parent directory is a symlink (on macOS
    # /tmp and /var both are) git says /private/var/... where the Run row says
    # /var/..., an exact-string lookup finds no owning run, and a worktree with
    # no run looks like a reclaimable orphan. That mistook live runs for
    # orphans and reclaimed their worktrees, so every path comparison here
    # resolves both sides first.
    def run_for(workspace, path)
      Run.find_by(target_root: path.to_s) ||
        workspace.runs.where.not(target_root: [ nil, "" ])
          .find { |run| same_path?(run.target_root, path) }
    end

    def same_path?(one, other)
      real_path(one) == real_path(other)
    end

    def real_path(path)
      Pathname(path).realpath
    rescue SystemCallError
      Pathname(path).expand_path
    end

    def protected_path?(source_root, path)
      same_path?(path, source_root) || path.basename.to_s == "main"
    end

    def dirty?(path)
      return false unless path.directory?

      git!(path, "status", "--porcelain").strip.present?
    rescue Error
      # If git cannot even report on it, treat it as dirty: refusing to remove
      # something we cannot inspect is the safe direction.
      true
    end

    # Clean, and HEAD is already on main or on a remote branch.
    def work_saved?(path)
      return false if dirty?(path)

      git_success?(path, "merge-base", "--is-ancestor", "HEAD", "main") ||
        git!(path, "branch", "--remotes", "--contains", "HEAD").strip.present?
    rescue Error
      false
    end

    def remove_worktree!(source_root, path, force: false)
      args = [ "worktree", "remove" ]
      args << "--force" if force
      git!(source_root, *args, path.to_s)
    end

    def prune!(source_root)
      git!(source_root, "worktree", "prune")
    end

    # The explicit per-run removal behind the run screen's button. `force`
    # here is the operator's own decision about their own uncommitted work.
    def remove_for_run!(run, force: false)
      raise Error, "Run #{run.run_id} has no managed worktree" if run.worktree_name.blank? || run.source_root.blank?

      source_root = Pathname(run.source_root)
      path = Pathname(run.target_root)
      raise Error, "Refusing to remove the source checkout" if protected_path?(source_root, path)
      raise Error, "Worktree has uncommitted changes; removing it would discard them" if !force && dirty?(path)

      remove_worktree!(source_root, path, force:)
      prune!(source_root)
      run
    end

    # Closing a session is the operator saying they are done with it. Removes
    # the worktree when nothing in it would be lost, and returns whether it
    # did. A pull-request comment can still reopen the run later:
    # PullRequestResume checks the branch back out first.
    def release!(run)
      return false if run.worktree_name.blank? || run.source_root.blank? || run.target_root.blank?

      source_root = Pathname(run.source_root)
      path = Pathname(run.target_root)
      return false if !path.directory? || protected_path?(source_root, path) || !work_saved?(path)

      remove_worktree!(source_root, path)
      prune!(source_root)
      true
    end

    def git_success?(root, *args)
      _output, _error, status = Open3.capture3("git", "-C", root.to_s, *args)
      status.success?
    end

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?

      raise Error, "git #{args.join(' ')} failed in #{root}: #{error.presence || output}"
    end
  end
end
