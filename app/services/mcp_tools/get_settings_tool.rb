module McpTools
  # The operator's settings (Setting), as update_settings sets them.
  # Admin-only, like update_settings.
  class GetSettingsTool < MCP::Tool
    tool_name "get_settings"
    description "Show Paneyard's operator settings: projectsDir, the directory create_workspace puts a project in when " \
      "given no path (null: not set, so it asks for a path), and defaultGithubOwner, the GitHub user or organization " \
      "create_workspace uses when given no owner (null: the logged-in gh user). update_settings changes them."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      ToolResponse.structured(Setting.to_h)
    end
  end
end
