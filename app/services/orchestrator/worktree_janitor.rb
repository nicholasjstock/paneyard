require "open3"

module Orchestrator
  # Reclaims run worktrees -- the only automatic removal in the system.
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
  # The rule for everything else is whether the work is saved elsewhere, not
  # how old it is. Removing a worktree never deletes its branch, so once the
  # session is over and the worktree is clean with HEAD already on main or
  # pushed, it holds nothing that is not somewhere else too and goes straight
  # away -- on close (release!) or on the next sweep. Anything else is kept
  # indefinitely and shown as a kept worktree (Run#kept_worktree?) until the
  # operator pushes, merges, or removes it.
  module WorktreeJanitor
    class Error < StandardError; end
    module_function

    def sweep_all
      Workspace.find_each.select { |workspace| Sandbox.allows_path?(workspace.root_path) }.sum { |workspace| sweep(workspace) }
    end

    # Whether `path` is a worktree git itself knows about, as opposed to a
    # directory that merely exists there. A run's target_root can point at a
    # directory for reasons that have nothing to do with a provisioned
    # worktree -- it defaults to the source checkout until provisioning
    # succeeds, and a worktree `git worktree remove` already reclaimed can
    # leave an inert leftover directory behind -- so Run#kept_worktree? asks
    # here rather than trusting File.directory? alone.
    def registered_worktree?(workspace, path)
      source_root = Pathname(workspace.source_root)
      return false unless source_root.directory?

      target = Pathname(path)
      return false if protected_path?(source_root, target)

      entries(source_root).any? { |entry| same_path?(entry, target) }
    end

    # Returns the number of worktrees removed.
    def sweep(workspace)
      source_root = Pathname(workspace.source_root)
      return 0 unless source_root.directory?

      removed = 0
      entries(source_root).each do |path|
        next if protected_path?(source_root, path)

        run = run_for(workspace, path)
        next unless reclaimable?(run, path:)

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
    # reclaimable on the same terms as a run whose session is over.
    def reclaimable?(run, path:)
      return false if run && !run.session_over?

      work_saved?(path)
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
      guard_sandbox!(path)
      args = [ "worktree", "remove" ]
      args << "--force" if force
      git!(source_root, *args, path.to_s)
    end

    def prune!(source_root)
      guard_sandbox!(source_root)
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

    # Closing a session is the operator saying they are done with it --
    # whether by Close session on the run screen or by closing the run's herdr
    # workspace by hand, which RunSessionReconcileJob picks up. Both call this.
    # Removes the worktree when nothing in it would be lost, and returns
    # whether it did.
    def release!(run)
      return false if run.worktree_name.blank? || run.source_root.blank? || run.target_root.blank?

      source_root = Pathname(run.source_root)
      path = Pathname(run.target_root)
      return false if !path.directory? || protected_path?(source_root, path) || !work_saved?(path)

      remove_worktree!(source_root, path)
      prune!(source_root)
      true
    end

    def guard_sandbox!(path)
      Sandbox.guard_path!(path, "remove worktrees in")
    rescue Sandbox::Violation => error
      raise Error, error.message
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
