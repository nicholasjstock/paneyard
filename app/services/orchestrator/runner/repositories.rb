require "open3"
require "shellwords"

module Orchestrator
  module Runner
    # Whether a directory on the runner's machine is a repository runs can
    # start from, and which branch they start from by default
    # (docs/operating.md, "Preparing a repository"). Any existing git checkout
    # will do, wherever it is and whatever branch it has checked out: runs
    # never work in it, they get their own worktree of it from herdr.
    #
    # Checking only looks. It never creates, fetches, switches or renames
    # anything; a problem comes back with the commands that would fix it, for
    # the operator to run. Worktrees.base_branch_problem is the same branch
    # rule a queued run is held to, so a workspace that registers does not
    # fail its first run over its branch.
    #
    # The one thing here that changes a checkout is switch_checkout!, which
    # puts it on the branch the operator opens its lobby on.
    module Repositories
      module_function

      # Returns { "repository_path", "default_base_branch", "origin_url",
      # "problems" => [{ "code", "message" }] }, problems empty when it can be
      # registered.
      #
      # `path` may be the checkout, any directory in it, or a linked worktree
      # of it (a run's, say): the repository is its main checkout. The default
      # branch is `default_base_branch` when given, else the repository's own
      # default -- origin's HEAD, then init.defaultBranch, then main or master
      # -- and never just whatever happens to be checked out.
      def check(path, default_base_branch: nil)
        raw = path.to_s.strip
        return result(raw, nil, nil, [ problem("path_blank", "path is required.") ]) if raw.empty?
        unless raw.start_with?("/", "~")
          return result(raw, nil, nil, [ problem("path_not_absolute", "path must be an absolute path (or start with ~), not #{raw.inspect}.") ])
        end

        given = Pathname(File.expand_path(raw)).cleanpath
        Sandbox.guard_path!(given, "register a workspace at")
        return result(given.to_s, nil, nil, [ problem("path_missing", "#{given} does not exist.") ]) unless given.exist?
        return result(given.to_s, nil, nil, [ problem("path_not_directory", "#{given} is not a directory.") ]) unless given.directory?
        unless Worktrees.git_success?(given, "rev-parse", "--is-inside-work-tree")
          return result(given.to_s, nil, nil, [ problem("not_git", "#{given} is not inside a git checkout. Clone the repository " \
            "first, e.g. git clone <repository-url> #{sh(given)}, and register that.") ])
        end

        repository = main_checkout(given)
        Sandbox.guard_path!(repository, "register a workspace at")
        branch = default_base_branch.to_s.strip.presence || detect_default_branch(repository)
        problems = [ branch_problem(repository, branch, explicit: default_base_branch.present?), origin_problem(repository) ].compact
        origin = Worktrees.origin_url(repository) if Worktrees.git_success?(repository, "remote", "get-url", "origin")
        result(repository.to_s, branch, origin.presence, problems)
      rescue Sandbox::Violation => error
        result(raw, nil, nil, [ problem("outside_sandbox", error.message) ])
      rescue Worktrees::Error => error
        result(raw, nil, nil, [ problem("git_error", error.message) ])
      end

      # Puts the repository's own checkout on `branch`, for the workspace's
      # lobby (Orchestrator::LobbyOpen), which the operator opens on the branch
      # they are integrating. Only a switch that cannot lose anything: it
      # refuses a checkout with uncommitted changes to tracked files, and
      # whatever else git refuses (an untracked file the branch would
      # overwrite, a branch checked out in a run's worktree) comes back as
      # git's own message. Never resets, stashes or forces.
      #
      # A branch only origin has (a pull request's, say) is fetched and
      # checked out as a local branch tracking it.
      #
      # Returns { "branch", "previous_branch", "switched" }; previous_branch
      # is nil on a detached HEAD.
      def switch_checkout!(repository_path:, branch:)
        repository = Pathname(repository_path)
        Sandbox.guard_path!(repository, "switch the checkout of")
        raise Worktrees::Error, "Repository does not exist: #{repository}" unless repository.directory?
        raise Worktrees::Error, "`#{branch}` is not a valid branch name" unless GitRef.branch?(branch)

        current = git_output(repository, "symbolic-ref", "--quiet", "--short", "HEAD")
        return switched(branch, current, false) if current == branch

        changed = Worktrees.git!(repository, "status", "--porcelain", "--untracked-files=no").lines.map(&:strip)
        if changed.any?
          listed = changed.first(5).join(", ") + (changed.size > 5 ? ", ..." : "")
          raise Worktrees::Error, "#{repository} has uncommitted changes (#{listed}) on #{current || 'a detached HEAD'}; " \
            "commit or stash them before switching it to #{branch}"
        end

        if Worktrees.local_branch?(repository, branch)
          Worktrees.git!(repository, "switch", branch)
        else
          unless Worktrees.git_success?(repository, "fetch", "origin", "refs/heads/#{branch}:refs/remotes/origin/#{branch}")
            raise Worktrees::Error, "#{repository} has no branch `#{branch}`, and origin has none either"
          end

          Worktrees.git!(repository, "switch", "--track", "origin/#{branch}")
        end
        switched(branch, current, true)
      rescue Sandbox::Violation => error
        raise Worktrees::Error, error.message
      end

      # The branch the repository's own checkout is on, or nil on a detached
      # HEAD.
      def current_branch(repository_path)
        repository = Pathname(repository_path)
        Sandbox.guard_path!(repository, "read the checkout of")
        git_output(repository, "symbolic-ref", "--quiet", "--short", "HEAD")
      rescue Sandbox::Violation => error
        raise Worktrees::Error, error.message
      end

      def switched(branch, previous_branch, switched)
        { "branch" => branch, "previous_branch" => previous_branch, "switched" => switched }
      end

      # The checkout that owns the repository: for a linked worktree, the main
      # one it was added from; otherwise the top of the checkout `path` is in.
      # A bare repository has no main checkout, so its linked worktree stands
      # for itself.
      def main_checkout(path)
        top = Pathname(Worktrees.git!(path, "rev-parse", "--show-toplevel").strip)
        common = Pathname(Worktrees.git!(path, "rev-parse", "--path-format=absolute", "--git-common-dir").strip)
        return top if common.basename.to_s != ".git"

        main = common.parent
        main.directory? && !Worktrees.git!(main, "rev-parse", "--is-bare-repository").strip.casecmp?("true") ? main : top
      end

      # origin's HEAD (what `git clone` checked out), the configured
      # init.defaultBranch, then main or master, whichever exists locally
      # first. nil when none does, which branch_problem then explains.
      def detect_default_branch(repository)
        remote_head = git_output(repository, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")&.delete_prefix("origin/")
        configured = git_output(repository, "config", "--get", "init.defaultBranch")
        [ remote_head, configured, "main", "master" ].compact.uniq.find { |name| Worktrees.local_branch?(repository, name) } ||
          remote_head
      end

      def branch_problem(repository, branch, explicit:)
        if branch.blank?
          return problem("no_default_branch", "Could not tell #{repository}'s default branch: it has no origin/HEAD, no " \
            "init.defaultBranch, and no main or master branch. Pass default_base_branch with the branch runs should start from.")
        end

        problem = Worktrees.base_branch_problem(repository, branch)
        problem && problem.merge("message" => "#{explicit ? 'default_base_branch' : 'The default branch'} " \
          "`#{branch}`: #{problem.fetch('message')}")
      end

      # Sessions push their own branch to origin when asked to, so a
      # repository without one could not finish that part of a run.
      def origin_problem(repository)
        return if Worktrees.git_success?(repository, "remote", "get-url", "origin")

        problem("no_origin", "#{repository} has no origin remote. Sessions push their branch to origin when asked to; " \
          "add it: git -C #{sh(repository)} remote add origin <repository-url>")
      end

      def git_output(repository, *args)
        output, _error, status = Open3.capture3("git", "-C", repository.to_s, *args)
        status.success? ? output.strip.presence : nil
      end

      def result(repository_path, default_base_branch, origin_url, problems)
        { "repository_path" => repository_path.to_s, "default_base_branch" => default_base_branch,
          "origin_url" => origin_url, "problems" => problems }
      end

      def problem(code, message)
        { "code" => code, "message" => message }
      end

      def sh(value)
        Shellwords.escape(value.to_s)
      end
    end
  end
end
