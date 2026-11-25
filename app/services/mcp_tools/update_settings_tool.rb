module McpTools
  # Sets the operator's settings (Setting), which apply straight away. A
  # projects directory is checked on the runner first (it must be an existing,
  # writable directory there); nothing is saved if anything is wrong.
  #
  # Admin-only (AdminMcpServer): where new projects go and which GitHub
  # account gets them is the operator's call.
  class UpdateSettingsTool < MCP::Tool
    tool_name "update_settings"
    description "Change Paneyard's operator settings; they apply at once, with no restart. Only the ones passed change; " \
      "an empty string clears one. projectsDir is where create_workspace puts a project when given no path: an " \
      "absolute path (~ allowed) of an existing directory, e.g. ~/Source. defaultGithubOwner is the GitHub user or " \
      "organization create_workspace creates or clones repositories under when given no owner (cleared: the " \
      "logged-in gh user). Set them only as the operator says. Returns every setting, as get_settings does."
    input_schema(
      properties: {
        projectsDir: { type: "string", description: "Directory new projects go in; empty clears it." },
        defaultGithubOwner: { type: "string", description: "Default GitHub owner for create_workspace; empty clears it." }
      },
      required: []
    )

    OWNER = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/

    def self.call(server_context:, projectsDir: nil, defaultGithubOwner: nil)
      changes = {}
      problems = []
      unless projectsDir.nil?
        if projectsDir.strip.empty?
          changes["projects_dir"] = nil
        else
          checked = Orchestrator::Runner.for(nil).check_projects_dir(path: projectsDir)
          problems.concat(checked.fetch("problems"))
          changes["projects_dir"] = checked.fetch("path")
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

      Setting.transaction { changes.each { |key, value| Setting[key] = value } }
      ToolResponse.structured(Setting.to_h)
    rescue Orchestrator::Runner::Error => error
      ToolResponse.error("Could not check the projects directory: #{error.message}", code: "runner_error")
    end
  end
end
