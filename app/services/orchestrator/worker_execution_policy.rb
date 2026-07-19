module Orchestrator
  class WorkerExecutionPolicy
    BASE_CLAUDE_TOOLS = %w[Bash Read Grep Glob ToolSearch].freeze
    WRITING_CLAUDE_TOOLS = %w[Edit Write].freeze

    WRITE_SCOPES = %w[artifact_only tests_only scoped_changes].freeze

    attr_reader :root_dir, :mode, :write_scope, :allowed_paths, :profile_name

    def initialize(root_dir:, mode:, write_scope:, allowed_paths:, profile_name: "worker")
      @root_dir = Pathname(root_dir).expand_path
      @mode = mode.to_s
      @write_scope = write_scope.to_s
      @allowed_paths = Array(allowed_paths).map { |path| normalize_path(path) }.uniq
      @profile_name = profile_name.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
      validate!
    end

    def repository_writable?
      write_scope.in?(%w[tests_only scoped_changes]) && allowed_paths.any?
    end

    def claude_tools
      tools = BASE_CLAUDE_TOOLS.dup
      tools.concat(WRITING_CLAUDE_TOOLS) if repository_writable?
      tools.join(",")
    end

    # Claude's Bash sandbox always permits its current directory. Workers are
    # therefore launched from an orchestrator-owned runtime directory and the
    # target workspace is added separately. Only these absolute paths become
    # writable inside Bash and its child processes.
    def claude_settings
      allow_rules = [
        "Bash",
        "Read(#{claude_absolute_path(root_dir)}/**)",
        "Grep",
        "Glob",
        "mcp__workflow__*"
      ]
      if repository_writable?
        allowed_absolute_paths.each do |path|
          allow_rules << "Edit(#{claude_absolute_path(path)})"
          allow_rules << "Write(#{claude_absolute_path(path)})"
        end
      end

      {
        "permissions" => { "allow" => allow_rules },
        "sandbox" => {
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => { "allowWrite" => allowed_absolute_paths.map(&:to_s) }
        }
      }
    end

    def codex_config_overrides
      filesystem = {
        ":minimal" => "read",
        ":tmpdir" => "write",
        ":workspace_roots" => { "." => "read" }.merge(allowed_paths.index_with { "write" })
      }

      [
        toml_assignment("default_permissions", profile_name),
        toml_assignment("permissions.#{profile_name}.filesystem", filesystem),
        toml_assignment("permissions.#{profile_name}.network", { "enabled" => false })
      ]
    end

    def allowed_absolute_paths
      @allowed_absolute_paths ||= allowed_paths.map { |path| root_dir.join(path).cleanpath }
    end

    private

    def normalize_path(path)
      value = path.to_s
      if value.blank? || Pathname(value).absolute? || value.end_with?("/") || value.match?(/[\*\?\[\]\{\}]/)
        raise ArgumentError, "Worker policy requires exact workspace-relative files: #{value.inspect}"
      end

      Pathname(value).cleanpath.to_s
    end

    def validate!
      raise ArgumentError, "Unknown worker write scope: #{write_scope}" unless WRITE_SCOPES.include?(write_scope)
      raise ArgumentError, "Worker permission profile name is empty" if profile_name.blank?

      if write_scope.in?(%w[tests_only scoped_changes]) && allowed_paths.empty?
        raise ArgumentError, "#{write_scope} workers require allowed paths"
      end
      if write_scope == "artifact_only" && allowed_paths.any?
        raise ArgumentError, "artifact_only workers cannot authorize repository paths"
      end

      real_root = root_dir.realpath
      allowed_absolute_paths.each do |path|
        unless path.to_s.start_with?("#{root_dir}#{File::SEPARATOR}")
          raise ArgumentError, "Worker path escapes target workspace: #{path}"
        end

        existing_ancestor = path
        existing_ancestor = existing_ancestor.parent until existing_ancestor.exist? || existing_ancestor.root?
        resolved = existing_ancestor.realpath.to_s
        unless resolved == real_root.to_s || resolved.start_with?("#{real_root}#{File::SEPARATOR}")
          raise ArgumentError, "Worker path resolves outside target workspace: #{path}"
        end
      end
    end

    def claude_absolute_path(path)
      "/#{Pathname(path).expand_path.to_s.delete_prefix('/')}"
    end

    def toml_assignment(key, value)
      "#{key}=#{toml_value(value)}"
    end

    def toml_value(value)
      case value
      when String
        value.to_json
      when TrueClass, FalseClass
        value.to_s
      when Hash
        "{#{value.map { |key, item| "#{key.to_json}=#{toml_value(item)}" }.join(',')}}"
      else
        raise ArgumentError, "Unsupported TOML policy value: #{value.inspect}"
      end
    end
  end
end
