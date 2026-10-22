module McpTools
  class ListWorkspacesTool < MCP::Tool
    tool_name "list_workspaces"
    description "List every registered workspace -- the names queue_run, list_runs, and get_run accept as " \
      "workspace -- with its repository checkout, the branch jobs start from by default, and how many runs it has " \
      "in flight. Match repositoryPath against the repository you are working in (its main checkout, if you are " \
      "in a linked worktree) to find the workspace for \"this repo\"; if none matches, that repository is not " \
      "registered, and register_workspace (where offered) adds it. isDefault marks the workspace list_runs " \
      "and get_run fall back to when called from outside a run with no workspace argument; queue_run never does. " \
      "lobby is the workspace's open lobby (the operator's integration session on its checkout), with the branch " \
      "it is on and whether its agent is still live, or null."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      default = Workspace.default
      active_counts = Run.active.group(:workspace_id).count

      ToolResponse.structured(
        workspaces: Workspace.order(:created_at).map do |workspace|
          {
            id: workspace.id,
            name: workspace.name,
            repository_path: workspace.repository_path,
            default_base_branch: workspace.default_base_branch,
            layout_yaml: workspace.layout,
            default_layout_yaml: Orchestrator::WorkspaceLayout::DEFAULT_YAML,
            is_default: workspace == default,
            active_runs: active_counts.fetch(workspace.id, 0),
            lobby: lobby(workspace)
          }
        end
      )
    end

    def self.lobby(workspace)
      status = Orchestrator::LobbyOpen.status(workspace)
      return unless status

      lobby = status.fetch(:lobby)
      { branch: lobby.branch, herdr_workspace: lobby.herdr_workspace_id, driver: lobby.driver, model: lobby.model,
        live: status.fetch(:live) }
    end
  end
end
