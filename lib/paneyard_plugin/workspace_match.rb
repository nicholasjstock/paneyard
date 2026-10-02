require "open3"
require_relative "../paneyard_sandbox"

module PaneyardPlugin
  # "Here", for an action invoked in herdr: which Paneyard workspace the
  # focused pane's directory belongs to, and which run, if the action was
  # invoked inside a run's own herdr workspace. Matching is over what the MCP
  # tools return (camelCase keys); the one git question -- which repository
  # a directory belongs to -- is asked separately (repository_of), so the
  # matching itself is tested without a daemon or a repository.
  module WorkspaceMatch
    module_function

    # The workspace whose repository holds `dir`: its checkout or anything in
    # it, or -- given `repository`, the main checkout git says `dir` belongs to
    # -- any linked worktree of it, wherever herdr put that. The deepest
    # repository wins when checkouts nest.
    def workspace_for(workspaces, dir, repository: nil)
      return nil if dir.to_s.empty?

      workspaces
        .select { |workspace| inside?(dir, workspace.fetch("repositoryPath")) || same?(repository, workspace.fetch("repositoryPath")) }
        .max_by { |workspace| workspace.fetch("repositoryPath").length }
    end

    # The run whose session opened the herdr workspace `herdr_workspace_id`.
    # `runs` is [[workspace, list_runs result], ...] (Client#runs).
    def run_in_herdr_workspace(runs, herdr_workspace_id)
      return nil if herdr_workspace_id.to_s.empty?

      runs.each do |workspace, listed|
        run = listed.fetch("runs").find { |candidate| candidate.dig("session", "herdrWorkspace") == herdr_workspace_id }
        return [ workspace, run ] if run
      end
      nil
    end

    # The main checkout of the repository `dir` is in (for a linked worktree,
    # the checkout it was added from), and the branch `dir` has checked out;
    # nils outside a checkout.
    def repository_of(dir)
      common, ok = git(dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return [ nil, nil ] unless ok

      top, = git(dir, "rev-parse", "--show-toplevel")
      branch, = git(dir, "branch", "--show-current")
      repository = File.basename(common) == ".git" ? File.dirname(common) : top
      [ repository, branch.to_s.empty? ? nil : branch ]
    end

    def git(dir, *args)
      output, status = Open3.capture2e("git", "-C", dir.to_s, *args)
      [ output.strip, status.success? ]
    rescue SystemCallError
      [ nil, false ]
    end

    def inside?(path, root)
      PaneyardSandbox.inside?(path, root)
    end

    def same?(one, other)
      !one.nil? && PaneyardSandbox.canonical(one) == PaneyardSandbox.canonical(other)
    end
  end
end
