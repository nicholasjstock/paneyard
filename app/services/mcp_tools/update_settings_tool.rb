module McpTools
  # Sets the operator's settings (Setting), which apply straight away, and the
  # local runner's projects directory (runners.projects_dir, unless
  # PANEYARD_PROJECTS_DIR sets it). A projects directory is checked on the
  # runner first (it must be an existing, writable directory there); nothing
  # is saved if anything is wrong.
  #
  # Admin-only (AdminMcpServer): where new projects go and which GitHub
  # account gets them is the operator's call.
  class UpdateSettingsTool < MCP::Tool
    tool_name "update_settings"
    description "Change Paneyard's operator settings; they apply at once, with no restart. Only the ones passed change; " \
      "an empty string clears one. projectsDir is the local runner's projects directory, where create_workspace puts a " \
      "project when given no path and where this machine clones a workspace it has no checkout of: an absolute path " \
      "(~ allowed) of an existing directory, e.g. ~/Source; cleared, it is ~/Source. It cannot be changed here while " \
      "PANEYARD_PROJECTS_DIR sets it (get_settings' projectsDirSource env): change that in the plugin's .env. defaultGithubOwner is the GitHub user or " \
      "organization create_workspace creates or clones repositories under when given no owner (cleared: the " \
      "logged-in gh user). Set them only as the operator says. Returns every setting, as get_settings does."
    input_schema(
      properties: {
        projectsDir: { type: "string", description: "The local runner's projects directory; empty clears it (back to ~/Source)." },
        defaultGithubOwner: { type: "string", description: "Default GitHub owner for create_workspace; empty clears it." }
      },
      required: []
    )

    OWNER = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/

    def self.call(server_context:, projectsDir: nil, defaultGithubOwner: nil)
      changes = {}
      problems = []
      local = RegisteredRunner.local
      projects_dir = :unchanged
      unless projectsDir.nil?
        if local.projects_dir_source == "env"
          problems << { "code" => "projects_dir_from_env", "message" => "The projects directory is #{local.clone_projects_dir}, " \
            "set by #{RegisteredRunner::PROJECTS_DIR_ENV_VAR} in the plugin's .env; change it there (the plugin's setup " \
            "action asks for it) and restart Paneyard." }
        elsif projectsDir.strip.empty?
          projects_dir = nil
        else
          checked = Orchestrator::Runner.for(local).check_projects_dir(path: projectsDir)
          problems.concat(checked.fetch("problems"))
          projects_dir = checked.fetch("path")
        end
      end
      unless defaultGithubOwner.nil?
        owner = defaultGithubOwner.strip
        problems << { "code" => "owner_invalid", "message" => "#{owner.inspect} is not a GitHub user or organization name." } unless owner.empty? || owner.match?(OWNER)
        changes["default_github_owner"] = owner
      end

      if problems.any?
        return ToolResponse.error(
          "Nothing was changed. Fix these and call update_settings again:\n" +
            problems.each_with_index.map { |problem, index| "#{index + 1}. #{problem.fetch('message')}" }.join("\n"),
          code: "settings_invalid", problems:
        )
      end

      Setting.transaction do
        changes.each { |key, value| Setting[key] = value }
        local.update!(projects_dir:) unless projects_dir == :unchanged
      end
      ToolResponse.structured(GetSettingsTool.present)
    rescue Orchestrator::Runner::Error => error
      ToolResponse.error("Could not check the projects directory: #{error.message}", code: "runner_error")
    end
  end
end
