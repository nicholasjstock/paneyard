module McpTools
  class ListWorkspacesTool < MCP::Tool
    tool_name "list_workspaces"
    description "List every registered workspace -- the names queue_run, list_runs, and get_run accept as " \
      "workspace -- with its source checkout path and how many runs it has in flight. Match sourceRoot against " \
      "the directory you are working in to find the workspace for \"this repo\"; if none matches, that repository " \
      "is not registered, and register_workspace (where offered) adds it. isDefault marks the workspace list_runs " \
      "and get_run fall back to when called from outside a run with no workspace argument; queue_run never does."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      default = Workspace.default
      active_counts = Run.active.group(:workspace_id).count

      ToolResponse.structured(
        workspaces: Workspace.order(:created_at).map do |workspace|
          {
            id: workspace.id,
            name: workspace.name,
            source_root: workspace.source_root,
            is_default: workspace == default,
            active_runs: active_counts.fetch(workspace.id, 0)
          }
        end
      )
    end
  end
end
