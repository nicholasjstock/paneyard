module McpTools
  # Registers a workspace from an MCP client (the herdr plugin's queue action
  # uses it too): Orchestrator::WorkspaceRegistration checks the repository and the name
  # first, and creates the row only when nothing is wrong. It never touches
  # the filesystem or the repository; a problem comes back with the commands
  # to fix it, for the caller to run.
  #
  # Admin-only (AdminMcpServer): a run session works inside one workspace and
  # has no business adding others.
  class RegisterWorkspaceTool < MCP::Tool
    tool_name "register_workspace"
    description "Register an existing git checkout as a workspace, so jobs can be queued in it. path can be the " \
      "checkout, any directory in it, or a linked worktree of it (the repository is its main checkout); the " \
      "checkout can have any branch checked out, and jobs never work in it -- each gets its own worktree, made by " \
      "herdr wherever its config puts worktrees. defaultBaseBranch is the branch jobs start from unless queue_run " \
      "names another; it defaults to the repository's own default branch (origin's HEAD, else main or master), " \
      "never just whatever is checked out, and must exist locally. The repository needs an origin remote. name " \
      "defaults to the repository's directory name. path is on the machine runner names (list_runners; default the " \
      "local runner), so a repository that is only on another machine registers with that runner; only that " \
      "runner's checkout is recorded, and any other runner clones the repository's origin into its projects " \
      "directory when a job first needs it there. Everything is checked first and nothing is created if anything " \
      "is wrong; every problem is returned with how to fix it. Nothing on disk is changed by this tool. On success, " \
      "returns the workspace as list_workspaces shows it, plus originUrl."
    input_schema(
      properties: {
        path: { type: "string", description: "Absolute path (~ allowed) of the checkout, or a directory in it." },
        name: { type: "string", description: "Unique workspace name, what queue_run and the other tools take as workspace. Defaults to the repository's directory name." },
        defaultBaseBranch: { type: "string", description: "Local branch jobs start from by default. Defaults to the repository's own default branch." },
        runner: { type: "string", description: "The runner (machine) path is on, from list_runners. Defaults to the local runner." }
      },
      required: %w[path]
    )

    def self.call(path:, server_context:, name: nil, defaultBaseBranch: nil, runner: nil)
      workspace, result = Orchestrator::WorkspaceRegistration.register(
        path:, name: name.to_s.strip.presence, default_base_branch: defaultBaseBranch.to_s.strip.presence,
        runner: Orchestrator::RunRunner.named!(runner)
      )
      problems = result.fetch("problems")
      if workspace.nil?
        return ToolResponse.error(
          "Nothing was registered. Fix these and call register_workspace again:\n" +
            problems.each_with_index.map { |problem, index| "#{index + 1}. #{problem.fetch('message')}" }.join("\n"),
          code: "workspace_invalid", problems:
        )
      end

      ToolResponse.structured(ListWorkspacesTool.present(workspace, active_runs: 0).merge(origin_url: result.fetch("origin_url")))
    rescue Orchestrator::RunRunner::Invalid => error
      ToolResponse.error(error.message, code: "runner_invalid")
    rescue ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
