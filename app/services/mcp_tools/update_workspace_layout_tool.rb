module McpTools
  # Admin-only: a layout controls commands that future run sessions start in
  # the operator's login shell. The Herdr plugin's layout popup uses this
  # instead of reaching into Rails or its database directly.
  class UpdateWorkspaceLayoutTool < MCP::Tool
    tool_name "update_workspace_layout"
    description "Replace a registered workspace's terminal pane layout. layout is YAML in the format returned by " \
      "list_workspaces as layoutYaml/defaultLayoutYaml; an empty string resets it to the default. The complete " \
      "layout is validated before it is saved, and invalid input changes nothing. This affects future runs only."
    input_schema(
      properties: {
        workspace: { type: "string", description: "Registered workspace name." },
        layout: { type: "string", description: "Complete layout YAML, or an empty string to use the default." }
      },
      required: %w[workspace layout]
    )

    def self.call(workspace:, layout:, server_context:)
      target = Workspace.find_by!(name: workspace)
      target.layout = layout
      unless target.save
        problems = target.errors.full_messages_for(:layout)
        return ToolResponse.error("Layout was not saved.", code: "workspace_layout_invalid", problems:)
      end

      ToolResponse.structured(
        workspace: target.name,
        layout_yaml: target.layout,
        using_default: target.layout.nil?
      )
    rescue ActiveRecord::RecordNotFound
      ToolResponse.error("No workspace named #{workspace.inspect}.", code: "workspace_not_found")
    end
  end
end
