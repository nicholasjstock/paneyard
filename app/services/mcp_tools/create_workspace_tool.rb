module McpTools
  # Gets a project ready and registers it as a workspace in one call
  # (Orchestrator::WorkspaceCreation), so an operator can queue its first job
  # from whatever session they are in, whatever of it exists already: nothing
  # yet, a local directory or repository with no GitHub repository, or a
  # GitHub repository not cloned here. Only the missing steps run.
  #
  # Admin-only (AdminMcpServer): it creates or clones GitHub repositories and
  # decides what this instance manages, which is the operator's call.
  class CreateWorkspaceTool < MCP::Tool
    tool_name "create_workspace"
    description "Get a project ready and register it as a workspace, so jobs can be queued in it right away -- only " \
      "when the operator asks. It is not a job: it finishes in seconds, so call it first and then queue jobs into the " \
      "new workspace (a later stage with queue_run's after: [an earlier runId] in that workspace). It works from whatever exists: with nothing at the path and nothing on GitHub it " \
      "makes the directory, runs git init on main with a first commit (a README and an AGENTS.md stub), creates the " \
      "GitHub repository <owner>/<name> as origin (private unless visibility says otherwise) and pushes main; with " \
      "nothing at the path but <owner>/<name> on GitHub, it clones that; for an existing directory or repository it " \
      "does only what is missing (git init, a first commit of just the README and AGENTS.md, the GitHub repository, " \
      "pushing the default branch), never committing other files there. Then it registers the workspace on the " \
      "repository's default branch. The path is path, else the projects directory setting (update_settings " \
      "projectsDir) joined with name; with neither it asks for one. name defaults to the path's directory name and " \
      "is also the GitHub repository's and the workspace's; owner defaults to the defaultGithubOwner setting, else " \
      "the gh user. Everything is checked first and nothing is done if anything is wrong; every problem comes back " \
      "with how to fix it. If a step then fails, it removes only a directory it made itself and nothing on GitHub, " \
      "says what exists, and calling it again with the same arguments carries on from there. On success, returns the " \
      "workspace as list_workspaces shows it, plus originUrl, githubUrl, steps (what was done) and notes."
    input_schema(
      properties: {
        name: { type: "string", description: "The project's name: its directory, GitHub repository and workspace name, e.g. lists. Defaults to path's directory name." },
        path: { type: "string", description: "Absolute path (~ allowed) of the project's directory, existing or not. Defaults to <projects directory>/<name>." },
        owner: { type: "string", description: "GitHub user or organization of the repository. Defaults to the defaultGithubOwner setting, else the logged-in gh user." },
        visibility: { type: "string", enum: %w[private public internal], description: "Visibility of a repository it creates. Default private." },
        description: { type: "string", description: "One line about the project, for a README it writes and a GitHub repository it creates." }
      },
      required: []
    )

    def self.call(server_context:, name: nil, owner: nil, visibility: nil, path: nil, description: nil)
      workspace, result = Orchestrator::WorkspaceCreation.create(
        name: name.to_s.strip.presence, owner: owner.to_s.strip.presence, visibility: visibility.to_s.strip.presence,
        path: path.to_s.strip.presence, description: description.to_s.strip.presence
      )
      return created(workspace, result) if workspace

      problems = result.fetch("problems")
      if problems.any?
        return ToolResponse.error(
          "Nothing was done. Fix these and call create_workspace again:\n" + numbered(problems),
          code: "workspace_invalid", problems:
        )
      end

      remaining = result.fetch("remaining", {})
      if (registration = result["registration_problems"])
        return ToolResponse.error(
          "#{result.fetch('repository_path')} is ready (#{steps_text(result)}), but it could not be registered. Fix " \
            "these, then call register_workspace with path #{result.fetch('repository_path')}:\n" + numbered(registration),
          code: "workspace_not_registered", problems: registration, remaining:
        )
      end

      ToolResponse.error(result.fetch("message"), code: "workspace_not_created", remaining:, steps: result.fetch("done", []))
    rescue ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end

    def self.created(workspace, result)
      ToolResponse.structured(
        ListWorkspacesTool.present(workspace, active_runs: 0).merge(
          origin_url: result["origin_url"], github_url: result["github_url"],
          github_repository: result["github_repository"], visibility: result["visibility"],
          steps: result.fetch("done"), notes: result.fetch("notes")
        )
      )
    end

    def self.steps_text(result)
      result.fetch("done", []).map { |step| step.tr("_", " ") }.join(", ").presence || "nothing needed doing"
    end

    def self.numbered(problems)
      problems.each_with_index.map { |problem, index| "#{index + 1}. #{problem.fetch('message')}" }.join("\n")
    end
  end
end
