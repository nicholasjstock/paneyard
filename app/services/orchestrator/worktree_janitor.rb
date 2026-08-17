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

        run = Run.find_by(target_root: path.to_s)
        next unless reclaimable?(run, now:)
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
    def reclaimable?(run, now:)
      return true if run.nil?
      return false if run.active?

      terminal_at = run.stopped_at || run.updated_at
      terminal_at.present? && terminal_at <= now - RETENTION
    end

    def entries(source_root)
      git!(source_root, "worktree", "list", "--porcelain")
        .split("\n")
        .filter_map { |line| Pathname(line.delete_prefix("worktree ")) if line.start_with?("worktree ") }
    end

    def protected_path?(source_root, path)
      path.expand_path == source_root.expand_path || path.basename.to_s == "main"
    end

    def dirty?(path)
      return false unless path.directory?

      git!(path, "status", "--porcelain").strip.present?
    rescue Error
      # If git cannot even report on it, treat it as dirty: refusing to remove
      # something we cannot inspect is the safe direction.
      true
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

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?

      raise Error, "git #{args.join(' ')} failed in #{root}: #{error.presence || output}"
    end
  end
end
