require "open3"

module Orchestrator
  module Runner
    # Git on the runner's machine: a workspace's `main` checkout and the
    # sibling worktrees runs work in. Which worktree belongs to which run, and
    # whether that run's session is over, is the orchestrator's knowledge
    # (Orchestrator::GitWorktree, Orchestrator::WorktreeJanitor); this only
    # answers questions about git and acts on paths it is given.
    #
    # Two rules make removal safe to run unattended:
    #
    #   * never `main`. The source checkout is where every worktree's real .git
    #     lives; removing it would take the whole workspace with it.
    #   * never a dirty worktree, unless forced. Uncommitted work in a failed
    #     run is exactly the work an operator is most likely to want back, so
    #     `force` is reserved for the operator's explicit per-run button.
    #
    # And removing a worktree never deletes its branch.
    module Worktrees
      class Error < Runner::Error; end
      module_function

      # A new worktree `name` beside source_root on branch paneyard/<name>,
      # from main's HEAD. When `current_target_root` already is that worktree
      # (a retried launch), it is reused as is.
      #
      # Returns { "source_root", "target_root", "branch", "base_sha", "reused" };
      # base_sha is nil when reused.
      def provision!(source_root:, name:, current_target_root: nil)
        source_root = Pathname(source_root)
        Sandbox.guard_path!(source_root, "provision a worktree in")
        branch = "paneyard/#{name}"
        worktree = source_root.parent.join(name)
        result = { "source_root" => source_root.to_s, "target_root" => worktree.to_s, "branch" => branch }
        if current_target_root.present? && Pathname(current_target_root).expand_path == worktree.expand_path && worktree.directory?
          return result.merge("base_sha" => nil, "reused" => true)
        end

        validate_source!(source_root)
        raise Error, "Worktree path already exists: #{worktree}" if worktree.exist?

        base_sha = git!(source_root, "rev-parse", "HEAD").strip
        git!(source_root, "worktree", "add", "-b", branch, worktree.to_s, base_sha)
        result.merge("base_sha" => base_sha, "reused" => false)
      rescue Sandbox::Violation => error
        raise Error, error.message
      end

      def validate_source!(source_root)
        raise Error, "Source checkout does not exist: #{source_root}" unless source_root.directory?
        raise Error, "Source checkout must be named main: #{source_root}" unless source_root.basename.to_s == "main"
        raise Error, "Source checkout is not a Git repository: #{source_root}" unless git_success?(source_root, "rev-parse", "--is-inside-work-tree")
        raise Error, "Source checkout must be on main" unless git!(source_root, "branch", "--show-current").strip == "main"
        raise Error, "Source checkout has no origin remote: #{source_root}" unless git_success?(source_root, "remote", "get-url", "origin")
      end

      # Whether `path` is a worktree git itself knows about, as opposed to a
      # directory that merely exists there. A run's target_root can point at a
      # directory for reasons that have nothing to do with a provisioned
      # worktree -- it defaults to the source checkout until provisioning
      # succeeds, and a worktree `git worktree remove` already reclaimed can
      # leave an inert leftover directory behind -- so this asks git rather
      # than trusting File.directory? alone.
      def registered?(source_root:, path:)
        source_root = Pathname(source_root)
        target = Pathname(path)
        return false unless target.directory? && source_root.directory?
        return false if protected_path?(source_root, target)

        entries(source_root).any? { |entry| same_path?(entry, target) }
      end

      # Removes every worktree of source_root whose work is saved elsewhere,
      # except those in `keep` (worktrees a run's session is still using).
      # A worktree no run owns at all is an orphan -- a run whose record was
      # destroyed, or a leftover from an earlier version of this tool -- and
      # goes on the same terms. Returns the number removed.
      def reclaim(source_root:, keep:)
        source_root = Pathname(source_root)
        return 0 unless source_root.directory?

        removed = 0
        entries(source_root).each do |path|
          next if protected_path?(source_root, path)
          next if keep.any? { |kept| same_path?(kept, path) }
          next unless work_saved?(path)

          remove!(source_root, path)
          removed += 1
        end
        # Also reaps entries whose directory an operator deleted by hand, which
        # git otherwise keeps listing as "prunable" forever.
        prune!(source_root)
        removed
      rescue Error => error
        Rails.logger.warn("WorktreeJanitor: #{source_root}: #{error.message}")
        removed || 0
      end

      # Removes `path` when nothing in it would be lost; returns whether it did.
      def release(source_root:, path:)
        source_root = Pathname(source_root)
        path = Pathname(path)
        return false if !path.directory? || protected_path?(source_root, path) || !work_saved?(path)

        remove!(source_root, path)
        prune!(source_root)
        true
      end

      # The explicit per-run removal. `force` is the operator's own decision
      # about their own uncommitted work.
      def remove(source_root:, path:, force: false)
        source_root = Pathname(source_root)
        path = Pathname(path)
        raise Error, "Refusing to remove the source checkout" if protected_path?(source_root, path)
        raise Error, "Worktree has uncommitted changes; removing it would discard them" if !force && dirty?(path)

        remove!(source_root, path, force:)
        prune!(source_root)
        nil
      end

      def origin_url(path)
        git!(Pathname(path), "config", "--get", "remote.origin.url").strip
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
      # /var/..., and an exact-string match finds no owning run, so a worktree
      # still in use looks like a reclaimable orphan. That mistook live runs for
      # orphans and reclaimed their worktrees, so every path comparison here
      # resolves both sides first.
      def same_path?(one, other)
        real_path(one) == real_path(other)
      end

      def real_path(path)
        Pathname(path).realpath
      rescue SystemCallError
        Pathname(path).expand_path
      end

      def protected_path?(source_root, path)
        same_path?(path, source_root) || Pathname(path).basename.to_s == "main"
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

      def remove!(source_root, path, force: false)
        guard_sandbox!(path)
        args = [ "worktree", "remove" ]
        args << "--force" if force
        git!(source_root, *args, path.to_s)
      end

      def prune!(source_root)
        guard_sandbox!(source_root)
        git!(source_root, "worktree", "prune")
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
end
