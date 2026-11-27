module McpTools
  # The operator's settings (Setting), as update_settings sets them, and the
  # local runner's projects directory (RegisteredRunner#clone_projects_dir).
  # Admin-only, like update_settings.
  class GetSettingsTool < MCP::Tool
    tool_name "get_settings"
    description "Show Paneyard's operator settings: projectsDir, the local runner's projects directory, where " \
      "create_workspace puts a project when given no path and where this machine clones a workspace it has no " \
      "checkout of (projectsDirSource says where it comes from: env, PANEYARD_PROJECTS_DIR in the plugin's .env, " \
      "which update_settings cannot change; setting, saved by update_settings; or default, ~/Source); and " \
      "defaultGithubOwner, the GitHub user or organization create_workspace uses when given no owner (null: the " \
      "logged-in gh user). A remote runner's projects directory is its own (list_runners). update_settings changes them."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      ToolResponse.structured(present)
    end

    def self.present
      local = RegisteredRunner.local
      { projects_dir: local.clone_projects_dir, projects_dir_source: local.projects_dir_source, **Setting.to_h.symbolize_keys }
    end
  end
end
