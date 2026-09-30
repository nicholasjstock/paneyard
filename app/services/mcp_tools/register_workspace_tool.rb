module McpTools
  # Registers a workspace from an MCP client, as Add workspace does in the web
  # UI: Orchestrator::WorkspaceRegistration checks the layout on disk and the
  # name first, and creates the row only when nothing is wrong. It never
  # touches the filesystem or the repository; a problem comes back with the
  # commands to fix it, for the caller to run.
  #
  # Admin-only (AdminMcpServer): a run session works inside one workspace and
  # has no business adding others.
  class RegisterWorkspaceTool < MCP::Tool
    tool_name "register_workspace"
    description "Register a repository as a workspace, so runs can be queued in it. A workspace is laid out as " \
      "<root>/main, a git checkout on branch main with an origin remote, with each run's worktree created beside " \
      "it. rootPath can be that root, the main checkout itself (the usual place an agent is opened), any " \
      "directory inside it, or a run's worktree: the root is worked out from it. The layout is checked first " \
      "and nothing is created if anything is wrong; every problem is returned with how to fix it. Nothing on " \
      "disk is changed by this tool. A checkout not named main (a plain clone) has no root to work out: follow " \
      "the returned fix, which clones it into <new root>/main, and register that; runs then work from that " \
      "clone, not the original directory. On success, returns the workspace as list_workspaces shows it, " \
      "including the root it chose."
    input_schema(
      properties: {
        name: { type: "string", description: "Unique workspace name, what queue_run and the other tools take as workspace." },
        rootPath: { type: "string", description: "Absolute path (~ allowed): the workspace root, or the main checkout or a directory in it." }
      },
      required: %w[name rootPath]
    )

    def self.call(name:, rootPath:, server_context:)
      workspace, result = Orchestrator::WorkspaceRegistration.register(name: name.to_s.strip, root_path: rootPath)
      problems = result.fetch("problems")
      if workspace.nil?
        return ToolResponse.error(
          "Nothing was registered. Fix these and call register_workspace again:\n" +
            problems.each_with_index.map { |problem, index| "#{index + 1}. #{problem.fetch('message')}" }.join("\n"),
          code: "workspace_invalid", problems:
        )
      end

      ToolResponse.structured(
        name: workspace.name,
        root_path: workspace.root_path,
        source_root: workspace.source_root,
        origin_url: result.fetch("origin_url"),
        is_default: workspace == Workspace.default,
        active_runs: 0
      )
    rescue ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
