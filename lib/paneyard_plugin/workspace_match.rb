require_relative "../paneyard_sandbox"

module PaneyardPlugin
  # "Here", for an action invoked in herdr: which Paneyard workspace the
  # focused pane's directory belongs to, and which run, if the action was
  # invoked inside a run's own herdr workspace. Pure functions over what the
  # MCP tools return (camelCase keys), so they are tested without a daemon.
  module WorkspaceMatch
    module_function

    # The workspace whose root holds `dir`: its main checkout, anything in it,
    # or a run worktree beside it. A workspace root is the parent of its
    # sourceRoot (<root>/main). The deepest root wins when roots nest.
    def workspace_for(workspaces, dir)
      return nil if dir.to_s.empty?

      workspaces
        .select { |workspace| inside?(dir, File.dirname(workspace.fetch("sourceRoot"))) }
        .max_by { |workspace| workspace.fetch("sourceRoot").length }
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

    # A name for registering `dir`'s workspace that no workspace has yet: the
    # workspace root's directory name, the root being what register_workspace
    # will work out -- the parent of the `main` checkout `dir` is in, or `dir`
    # itself when it is in none (a root, or a plain clone the tool will then
    # explain how to lay out).
    def registration_name(dir, taken)
      path = File.expand_path(dir)
      main = path
      main = File.dirname(main) until File.basename(main) == "main" || File.dirname(main) == main
      root = File.basename(main) == "main" ? File.dirname(main) : path
      base = File.basename(root).gsub(/[^A-Za-z0-9._-]+/, "-")
      return base unless taken.include?(base)

      (2..).each do |n|
        name = "#{base}-#{n}"
        return name unless taken.include?(name)
      end
    end

    def inside?(path, root)
      PaneyardSandbox.inside?(path, root)
    end
  end
end
