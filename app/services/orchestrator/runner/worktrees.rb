require "open3"
require "shellwords"

module Orchestrator
  module Runner
    # Run worktrees on the runner's machine. herdr makes and removes them
    # (worktree.create puts each where the operator's herdr config says, and
    # opens it as the run's herdr workspace; worktree.remove takes it away);
    # this module decides, with git, whether a removal is safe. Which worktree
    # belongs to which run, and whether that run's session is over, is the
    # orchestrator's knowledge (Orchestrator::GitWorktree,
    # Orchestrator::WorktreeJanitor): this only acts on the paths it is given,
    # never on whatever else `git worktree list` shows.
    #
    # Three rules make removal safe to run unattended:
    #
    #   * never the repository's own checkout, or anything that is not a linked
    #     worktree of it. herdr refuses a primary checkout too
    #     (not_linked_worktree); this does not rely on that.
    #   * never a dirty worktree, unless forced. Uncommitted work in a failed
    #     run is exactly the work an operator is most likely to want back, so
    #     `force` is reserved for the operator's explicit per-run button.
    #   * only work that is saved: HEAD already in the run's own base branch,
    #     or on a remote branch.
    #
    # And removing a worktree never deletes its branch.
    module Worktrees
      class Error < Runner::Error; end
      module_function

      # A worktree of `repository_path` on `branch`, from `base_branch` (a
      # local branch, whatever the repository has checked out), made and
      # opened by herdr. When `current_target_root` already is a worktree of
      # the repository (a retried launch, or a reopened run whose worktree was
      # kept), herdr reopens it instead.
      #
      # When `branch` already exists (a reopened run whose worktree was
      # removed), the worktree is made on it as it is, and base_branch plays no
      # part: herdr's worktree.create checks an existing branch out at its own
      # commit, ignoring `base` (confirmed live on herdr 0.7.5, with and
      # without a base), so the run's committed work comes back and a base
      # branch deleted since does not matter. herdr picks the path from the
      # branch name, so the worktree normally comes back where it was.
      #
      # Returns { "repository_path", "target_root", "branch", "base_sha",
      # "reused", "workspace_id", "tab_id", "pane_id" }: the herdr workspace
      # and its root pane, which becomes the agent's. base_sha is nil when
      # reused, or when the branch already existed.
      def provision!(repository_path:, branch:, base_branch:, label:, current_target_root: nil)
        repository = Pathname(repository_path)
        Sandbox.guard_path!(repository, "provision a worktree in")
        raise Error, "Repository does not exist: #{repository}" unless repository.directory?

        if current_target_root.present? && registered?(repository_path: repository, path: current_target_root)
          opened = Herdr.worktree_open(cwd: repository.to_s, path: current_target_root.to_s, label:, focus: false)
          return provisioned(repository, opened, branch:, base_sha: nil, reused: true)
        end

        if local_branch?(repository, branch)
          created = Herdr.worktree_create(cwd: repository.to_s, branch:, base: nil, label:, focus: false)
          return provisioned(repository, created, branch:, base_sha: nil, reused: false)
        end

        problem = base_branch_problem(repository, base_branch)
        raise Error, "Base branch `#{base_branch}`: #{problem.fetch('message')}" if problem

        created = Herdr.worktree_create(cwd: repository.to_s, branch:, base: base_branch, label:, focus: false)
        path = created.dig("worktree", "path")
        provisioned(repository, created, branch:, base_sha: path && git!(Pathname(path), "rev-parse", "HEAD").strip, reused: false)
      rescue Sandbox::Violation => error
        raise Error, error.message
      rescue Herdr::Error => error
        raise Error, "herdr could not create the worktree: #{error.message}"
      end

      def provisioned(repository, herdr_result, branch:, base_sha:, reused:)
        workspace = herdr_result.fetch("workspace")
        root_pane = herdr_result["root_pane"] || first_pane(workspace.fetch("workspace_id"))
        {
          "repository_path" => repository.to_s, "target_root" => herdr_result.dig("worktree", "path"),
          "branch" => herdr_result.dig("worktree", "branch").presence || branch, "base_sha" => base_sha, "reused" => reused,
          "workspace_id" => workspace.fetch("workspace_id"), "tab_id" => root_pane.fetch("tab_id"),
          "pane_id" => root_pane.fetch("pane_id")
        }
      end

      # worktree.open answers with the workspace only; its first pane is the
      # one a reopened workspace starts with.
      def first_pane(workspace_id)
        Herdr.pane_list(workspace_id:).first || raise(Error, "herdr opened workspace #{workspace_id} with no pane")
      end

      # nil when a run can start from `branch` in `repository`, else
      # { "code", "message" } with how to fix it. A local branch is required:
      # herdr creates the run's branch from it, and the run merges back into it.
      def base_branch_problem(repository, branch)
        repository = Pathname(repository)
        unless GitRef.branch?(branch)
          return problem("base_branch_invalid", "#{branch.to_s.inspect} is not a valid branch name.")
        end
        return nil if local_branch?(repository, branch)

        dir = Shellwords.escape(repository.to_s)
        name = Shellwords.escape(branch)
        fix =
          if git_success?(repository, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch}^{commit}")
            "It exists on origin; create it locally (this checks nothing out): git -C #{dir} branch #{name} origin/#{name}"
          else
            "Check the name with git -C #{dir} branch --list, or git -C #{dir} fetch origin first."
          end
        problem("base_branch_missing", "there is no local branch `#{branch}` in #{repository}. #{fix}")
      end

      # Whether the repository has `branch` as a local branch.
      def branch_exists?(repository_path:, branch:)
        GitRef.branch?(branch) && local_branch?(Pathname(repository_path), branch)
      end

      def local_branch?(repository, branch)
        git_success?(repository, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}^{commit}")
      end

      def problem(code, message)
        { "code" => code, "message" => message }
      end

      # Whether `path` is a linked worktree of the repository that git knows
      # about, as opposed to a directory that merely exists there or the
      # repository's own checkout.
      def registered?(repository_path:, path:)
        repository = Pathname(repository_path)
        target = Pathname(path)
        return false unless target.directory? && repository.directory?
        return false if protected_path?(repository, target)

        linked_entries(repository).any? { |entry| same_path?(entry, target) }
      end

      # Removes each of `worktrees` ([{ "path", "base_branch" }], the run
      # worktrees whose sessions are over) whose work is saved. Nothing else of
      # the repository's is looked at. Returns the number removed.
      def reclaim(repository_path:, worktrees:)
        worktrees.count do |worktree|
          release(repository_path:, path: worktree.fetch("path"), base_branch: worktree.fetch("base_branch"))
        rescue Error => error
          Rails.logger.warn("WorktreeJanitor: #{worktree.fetch('path')}: #{error.message}")
          false
        end
      end

      # Removes `path` when nothing in it would be lost; returns whether it did.
      def release(repository_path:, path:, base_branch:)
        repository = Pathname(repository_path)
        path = Pathname(path)
        return false unless registered?(repository_path: repository, path:) && work_saved?(path, repository:, base_branch:)

        remove!(repository, path)
        true
      end

      # The explicit per-run removal. `force` is the operator's own decision
      # about their own uncommitted work.
      def remove(repository_path:, path:, force: false)
        repository = Pathname(repository_path)
        path = Pathname(path)
        raise Error, "Refusing to remove the repository's own checkout" if protected_path?(repository, path)
        raise Error, "#{path} is not a worktree of #{repository}" unless registered?(repository_path: repository, path:)
        raise Error, "Worktree has uncommitted changes; removing it would discard them" if !force && dirty?(path)

        remove!(repository, path, force:)
        nil
      end

      def origin_url(path)
        git!(Pathname(path), "config", "--get", "remote.origin.url").strip
      end

      # The linked worktrees git lists for the repository: every entry after
      # the first, which is the main checkout (or the bare repository).
      def linked_entries(repository)
        git!(repository, "worktree", "list", "--porcelain")
          .split("\n")
          .filter_map { |line| Pathname(line.delete_prefix("worktree ")) if line.start_with?("worktree ") }
          .drop(1)
      end

      # `git worktree list` reports every path with its symlinks resolved, while
      # a Run's target_root is whatever string provisioned it. Those two are not
      # interchangeable: anywhere a parent directory is a symlink (on macOS
      # /tmp and /var both are) git says /private/var/... where the Run row says
      # /var/..., so every path comparison here resolves both sides first.
      def same_path?(one, other)
        real_path(one) == real_path(other)
      end

      def real_path(path)
        Pathname(path).realpath
      rescue SystemCallError
        Pathname(path).expand_path
      end

      def protected_path?(repository, path)
        same_path?(path, repository) ||
          same_path?(path, git!(repository, "rev-parse", "--show-toplevel").strip)
      rescue Error
        true
      end

      def dirty?(path)
        return false unless path.directory?

        git!(path, "status", "--porcelain").strip.present?
      rescue Error
        # If git cannot even report on it, treat it as dirty: refusing to remove
        # something we cannot inspect is the safe direction.
        true
      end

      # Clean, and HEAD is already in the run's base branch or on a remote
      # branch. A base branch that no longer exists saves nothing.
      def work_saved?(path, repository:, base_branch:)
        return false if dirty?(path)

        (local_branch?(repository, base_branch) &&
          git_success?(path, "merge-base", "--is-ancestor", "HEAD", "refs/heads/#{base_branch}")) ||
          git!(path, "branch", "--remotes", "--contains", "HEAD").strip.present?
      rescue Error
        false
      end

      # herdr removes only a worktree whose workspace is open, so open it first
      # (worktree.open returns it if it already is); removing it closes it.
      def remove!(repository, path, force: false)
        guard_sandbox!(repository)
        opened = Herdr.worktree_open(cwd: repository.to_s, path: path.to_s, focus: false)
        Herdr.worktree_remove(opened.fetch("workspace").fetch("workspace_id"), force:)
      rescue Herdr::Error => error
        raise Error, "herdr could not remove #{path}: #{error.message}"
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
