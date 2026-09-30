require "shellwords"

module Orchestrator
  module Runner
    # Whether a directory on the runner's machine is laid out the way a
    # workspace's runs need it (docs/operating.md, "Preparing a repository"):
    # a root holding a `main` child that is a git checkout of its own, on
    # branch `main`, with an `origin` remote. The checkout's own rules are
    # Worktrees.source_problems, the same ones a launch enforces, so a root
    # that passes here does not fail the first run for its layout.
    #
    # This only looks. It never creates, clones, moves or renames anything;
    # every problem comes back with the commands that would fix it, for the
    # operator to run.
    module WorkspaceRoots
      module_function

      # Returns { "root_path", "source_root", "origin_url", "problems" }, where
      # root_path is the expanded path, origin_url is nil when there is none,
      # and problems is [{ "code", "message" }], empty when the root is fine.
      #
      # A path inside a git checkout -- the `main` checkout itself, which is
      # where an agent is usually opened, any directory in it, or a run
      # worktree beside it -- is taken to mean that checkout's workspace, and
      # root_path comes back as the directory holding `main`. Only a checkout
      # not laid out that way is a problem, since it has no workspace root to
      # go up to.
      def check(root_path)
        raw = root_path.to_s.strip
        return result(raw, nil, [ problem("root_path_blank", "root_path is required.") ]) if raw.empty?
        unless raw.start_with?("/", "~")
          return result(raw, nil, [ problem("root_path_not_absolute", "root_path must be an absolute path (or start with ~), not #{raw.inspect}.") ])
        end

        root = Pathname(File.expand_path(raw)).cleanpath
        Sandbox.guard_path!(root, "register a workspace at")
        return result(root.to_s, nil, [ problem("root_path_missing", "#{root} does not exist. #{clone_hint(root)}") ]) unless root.exist?
        return result(root.to_s, nil, [ problem("root_path_not_directory", "#{root} is not a directory.") ]) unless root.directory?

        root = enclosing_root(root) || root
        Sandbox.guard_path!(root, "register a workspace at")
        source = root.join("main")
        problems = source.exist? ? Worktrees.source_problems(source) : [ missing_checkout(root) ]
        origin = Worktrees.origin_url(source) if problems.none? { |entry| entry["code"].in?(%w[source_not_git no_origin]) } && source.directory?
        result(root.to_s, origin.presence, problems)
      rescue Sandbox::Violation => error
        result(raw, nil, [ problem("outside_sandbox", error.message) ])
      rescue Worktrees::Error => error
        result(raw, nil, [ problem("git_error", error.message) ])
      end

      # For a path with no `main` child that lies inside a git checkout: the
      # workspace root it belongs to when the checkout is named `main` or is a
      # worktree of a `main` beside it, else the checkout itself (a plain
      # clone, reported by missing_checkout). Spelled as given -- git answers with symlinks
      # resolved, /private/var for /var on macOS -- by walking up the given
      # path to the checkout. nil when the path is not in a checkout at all.
      def enclosing_root(path)
        return if path.join("main").exist?
        return unless Worktrees.git_success?(path, "rev-parse", "--is-inside-work-tree")

        top = Worktrees.git!(path, "rev-parse", "--show-toplevel").strip
        checkout = path.ascend.find { |ancestor| Worktrees.same_path?(ancestor, top) } || Pathname(top)
        return checkout.parent if checkout.basename.to_s == "main"

        # A run's worktree (or any linked worktree) beside a `main` checkout
        # belongs to the same workspace as that checkout.
        common = Pathname(Worktrees.git!(checkout, "rev-parse", "--path-format=absolute", "--git-common-dir").strip)
        main = checkout.parent.join("main")
        main.exist? && Worktrees.same_path?(common, main.join(".git")) ? checkout.parent : checkout
      end

      # No <root>/main: either a plain clone with no layout around it, which
      # gets the commands to lay it out, or a directory with no checkout yet.
      def missing_checkout(root)
        if top_level?(root)
          new_root = root.parent.join("#{root.basename}-workspace")
          origin = Worktrees.git_success?(root, "remote", "get-url", "origin") ? sh(Worktrees.origin_url(root)) : "<repository-url>"
          problem("root_path_is_repository",
            "#{root} is itself a git checkout, but a workspace root must hold the checkout as a child named `main` " \
            "(<root>/main), with each run's worktree created beside it. Clone it into a new root and register that:\n" \
            "  mkdir -p #{sh(new_root)}\n  git clone #{origin} #{sh(new_root.join('main'))}\n" \
            "or move this checkout down a level yourself (#{sh(root)} -> #{sh(root.join('main'))}) and register #{root} again.")
        else
          problem("source_missing", "There is no `main` checkout at #{root.join('main')}. #{clone_hint(root)}")
        end
      end

      def clone_hint(root)
        "A workspace root holds the repository's checkout as `main/`; set it up with:\n" \
          "  mkdir -p #{sh(root)}\n  git clone <repository-url> #{sh(root.join('main'))}"
      end

      def top_level?(path)
        Worktrees.git_success?(path, "rev-parse", "--is-inside-work-tree") &&
          Worktrees.same_path?(Worktrees.git!(path, "rev-parse", "--show-toplevel").strip, path)
      end

      def result(root_path, origin_url, problems)
        source_root = root_path.start_with?("/") ? File.join(root_path, "main") : nil
        { "root_path" => root_path, "source_root" => source_root, "origin_url" => origin_url, "problems" => problems }
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
