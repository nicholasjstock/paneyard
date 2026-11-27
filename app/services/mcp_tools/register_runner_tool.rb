module McpTools
  # Registers a second machine's runner-only process (bin/runner) as a remote
  # runner (Orchestrator::RunnerRegistration). The herdr plugin there calls it
  # on every start, so calling it again with the same name updates the
  # runner rather than failing.
  #
  # Admin-only (AdminMcpServer): which machines this orchestrator hands
  # sessions to, with full access to their checkouts, is the operator's call.
  class RegisterRunnerTool < MCP::Tool
    tool_name "register_runner"
    description "Register (or update) a remote runner: another machine's Paneyard runner-only process, which can " \
      "then host this orchestrator's sessions in its own herdr, against its own checkouts. url is where this " \
      "orchestrator reaches it (its tailnet URL, e.g. from tailscale serve); orchestratorUrl is where sessions on " \
      "that machine reach this orchestrator. checkouts says where registered workspaces are checked out on that " \
      "machine; each is checked there, and one that is wrong is reported in problems without failing the rest. " \
      "projectsDir is the directory on that machine where it clones a workspace it has no checkout of, as " \
      "<projectsDir>/<workspace name>, when a job is queued or moved there (and where create_workspace puts a new " \
      "project there); without one it gets only the workspaces it has checkouts of. " \
      "Nothing is saved unless the runner answers at url. Calling it again with the same name is safe: it updates " \
      "the urls, the projects directory and the checkouts it names."
    input_schema(
      properties: {
        name: { type: "string", description: "Unique runner name, e.g. the machine's hostname. Not \"local\"." },
        url: { type: "string", description: "The runner's base URL as this orchestrator reaches it." },
        orchestratorUrl: { type: "string", description: "This orchestrator's base URL as sessions on that machine reach it." },
        projectsDir: { type: "string", description: "Absolute path on that machine where it clones workspaces, e.g. /home/me/Source." },
        checkouts: {
          type: "array",
          items: {
            type: "object",
            properties: {
              workspace: { type: "string", description: "Workspace name." },
              path: { type: "string", description: "The repository's checkout on that machine." }
            },
            required: %w[workspace path]
          }
        }
      },
      required: %w[name url orchestratorUrl]
    )

    def self.call(name:, url:, orchestratorUrl:, server_context:, checkouts: [], projectsDir: nil)
      result = Orchestrator::RunnerRegistration.register(name:, url:, orchestrator_url: orchestratorUrl, checkouts:,
        projects_dir: projectsDir)
      runner = result.fetch(:runner)
      ToolResponse.structured(
        name: runner.name,
        url: runner.url,
        orchestrator_url: runner.orchestrator_url,
        projects_dir: runner.clone_projects_dir,
        hostname: result.fetch(:hostname),
        checkouts: runner.workspace_checkouts.includes(:workspace).order(:id).map do |checkout|
          { workspace: checkout.workspace.name, repository_path: checkout.repository_path }
        end,
        problems: result.fetch(:problems)
      )
    rescue Orchestrator::RunnerRegistration::Invalid, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message, code: "runner_invalid")
    end
  end
end
