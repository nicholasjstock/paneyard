require_relative "../paneyard_sandbox/mcp_client"

module PaneyardPlugin
  # The plugin's view of a running daemon: its /mcp/admin tools, the same ones
  # an operator's own Claude Code uses, so the herdr surface adds no API of
  # its own. Results are the tools' structuredContent (camelCase keys).
  #
  # For a Paneyard on another machine, `paths` (a Remote) translates
  # repository paths, so callers see this machine's checkouts throughout.
  class Client
    Error = PaneyardSandbox::McpClient::Error

    # Setting a project up can create, clone and push a GitHub repository,
    # which takes longer than any other call.
    PROJECT_TIMEOUT = 300

    def initialize(url, paths: nil)
      @url = url
      @mcp = PaneyardSandbox::McpClient.new("#{url}/mcp/admin", client_name: "paneyard-herdr-plugin")
      @paths = paths
    end

    def workspaces
      @mcp.call_tool("list_workspaces").fetch("workspaces").map { |workspace| local_workspace(workspace) }
    end

    # [workspace name, list_runs result] for every workspace.
    def runs(include_finished: true, limit: 20)
      workspaces.map do |workspace|
        listed = @mcp.call_tool("list_runs", workspace: workspace.fetch("name"), includeFinished: include_finished, limit:)
        [ workspace, listed ]
      end
    end

    def run(run_id, workspace:)
      @mcp.call_tool("get_run", runId: run_id, workspace:)
    end

    def queue(task:, workspace:, base_branch: nil, driver: nil, model: nil)
      @mcp.call_tool("queue_run", task:, workspace:, **{ baseBranch: base_branch, driver:, model: }.compact)
    end

    # {"driver", "defaultModel", "models" => [{"id", "label"}]}
    def models(driver, workspace:)
      @mcp.call_tool("list_models", driver:, workspace:)
    end

    # The server names it after the repository and works out its default branch.
    def register(path:)
      local_workspace(@mcp.call_tool("register_workspace", path: @paths ? @paths.to_remote(path) : path))
    end

    # {"projectsDir", "defaultGithubOwner"}, nil for unset; projectsDir as a
    # path on this machine.
    def settings
      local_settings(@mcp.call_tool("get_settings"))
    end

    def update_projects_dir(path)
      local_settings(@mcp.call_tool("update_settings", projectsDir: remote_path(path)))
    end

    # A project set up and registered from whatever exists (create_workspace):
    # by name, in the projects directory, or at an existing path. Returns the
    # workspace, plus "steps", "notes", "githubUrl".
    def create_workspace(name: nil, path: nil, owner: nil, visibility: nil)
      arguments = { name:, path: path && remote_path(path), owner:, visibility: }.compact
      mcp = PaneyardSandbox::McpClient.new("#{@url}/mcp/admin", client_name: "paneyard-herdr-plugin", timeout: PROJECT_TIMEOUT)
      local_workspace(mcp.call_tool("create_workspace", **arguments))
    end

    def update_layout(workspace:, layout:)
      @mcp.call_tool("update_workspace_layout", workspace:, layout:)
    end

    def close(run_id, workspace:)
      @mcp.call_tool("close_session", runId: run_id, workspace:)
    end

    def reopen(run_id, workspace:)
      @mcp.call_tool("reopen_session", runId: run_id, workspace:)
    end

    # {"state", "branch", "switchedFrom", "herdrWorkspace", ...}: the
    # workspace's lobby, opened on branch (or found open on it).
    def open_lobby(workspace:, branch: nil, driver: nil, model: nil)
      @mcp.call_tool("open_lobby", workspace:, **{ branch:, driver:, model: }.compact)
    end

    # Lets a queued run start without waiting for the runs it was queued after.
    def release(run_id, workspace:)
      @mcp.call_tool("update_run_dependencies", runId: run_id, workspace:, after: [])
    end

    private

    def remote_path(path)
      @paths ? @paths.to_remote(path) : path
    end

    def local_settings(settings)
      return settings unless @paths && settings["projectsDir"]

      settings.merge("projectsDir" => @paths.to_local(settings["projectsDir"]))
    end

    def local_workspace(workspace)
      return workspace unless @paths && workspace["repositoryPath"]

      workspace.merge("repositoryPath" => @paths.to_local(workspace["repositoryPath"]))
    end
  end
end
