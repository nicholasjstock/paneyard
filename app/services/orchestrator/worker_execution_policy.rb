require "open3"

module Orchestrator
  class WorkerExecutionPolicy
    BASE_CLAUDE_TOOLS = %w[Bash Read Grep Glob ToolSearch].freeze
    WRITING_CLAUDE_TOOLS = %w[Edit Write].freeze

    WRITE_SCOPES = %w[source_protected tests_only scoped_changes].freeze

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
      cache_writable_absolute_paths.each do |path|
        allow_rules << "Edit(#{claude_absolute_path(path)})"
        allow_rules << "Write(#{claude_absolute_path(path)})"
      end

      {
        "permissions" => { "allow" => allow_rules },
        "sandbox" => {
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => { "allowWrite" => (allowed_absolute_paths + cache_writable_absolute_paths).map(&:to_s) }
        }
      }
    end

    # :root read plus open network deliberately widen every worker's sandbox
    # beyond the target repo -- confirmed necessary (not repo-specific) by
    # reproducing the failure directly with `codex sandbox --log-denials`:
    # any host toolchain manager (asdf, nvm, rbenv, ...) installs outside the
    # workspace root under $HOME or a package-manager prefix (e.g. asdf's
    # shim execs a dispatcher under /usr/local/opt/asdf, a second path
    # outside $HOME), so no finite set of extra readable roots covers every
    # repo/host; and Docker's Unix-socket connect is classified as network
    # activity by the seatbelt sandbox with no working per-socket allowlist
    # exposed through `codex exec` (only the separate `codex sandbox` debug
    # command's --allow-unix-socket does). Write access to tracked/trackable
    # source is unaffected -- it stays exactly as narrow as before (:tmpdir
    # plus explicit allowed_paths). write_scope exists to protect source the
    # repo (and acceptance criteria) care about, not to forbid every write --
    # a gitignored path is the repo's own declaration that it isn't source,
    # so cache_writable_absolute_paths grants it regardless of write_scope.
    # Confirmed necessary the same way: a source_protected verification worker
    # hit EPERM writing Vite's node_modules/.vite-temp bundled-config scratch
    # file, a real write every vitest invocation needs and no write_scope
    # was ever meant to block.
    def codex_config_overrides
      filesystem = {
        ":minimal" => "read",
        ":tmpdir" => "write",
        ":root" => "read",
        ":workspace_roots" => { "." => "read" }
          .merge(allowed_paths.index_with { "write" })
          .merge(git_ignored_relative_paths.index_with { "write" })
      }

      [
        toml_assignment("default_permissions", profile_name),
        toml_assignment("permissions.#{profile_name}.filesystem", filesystem),
        toml_assignment("permissions.#{profile_name}.network", { "enabled" => true })
      ]
    end

    def allowed_absolute_paths
      @allowed_absolute_paths ||= allowed_paths.map { |path| root_dir.join(path).cleanpath }
    end

    def cache_writable_absolute_paths
      @cache_writable_absolute_paths ||= git_ignored_relative_paths.map { |path| root_dir.join(path).cleanpath }
    end

    # Deliberately every gitignored *directory* in the repo, not a hardcoded
    # list of known cache directory names (node_modules/.vite-temp,
    # __pycache__, .turbo, ...) -- that list is unenumerable across
    # repos/toolchains (the same lesson as :root above), while .gitignore is
    # each repo's own authoritative, already-existing declaration of what
    # isn't source. Individual gitignored *files* are deliberately excluded:
    # a real repo's ignore list also covers .env.local, local secrets, DB
    # dumps, and IDE settings (confirmed against a real target repo) --
    # exactly what "protect the source code" must still protect. Caches and
    # build output are reliably whole directories a tool regenerates; `git
    # ls-files --directory` reports a fully-ignored directory as one
    # trailing-slash entry instead of every file inside it, which is the
    # signal used here to tell the two apart.
    def git_ignored_relative_paths
      @git_ignored_relative_paths ||= begin
        output, _stderr, status = Open3.capture3(
          "git", "-C", root_dir.to_s, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"
        )
        return [] unless status.success?

        output.lines.map(&:chomp).select { |line| line.end_with?("/") }.map { |line| line.delete_suffix("/") }.reject(&:blank?)
      rescue StandardError
        []
      end
    end

    private

    def normalize_path(path)
      value = path.to_s
      if value.blank? || Pathname(value).absolute? || value.match?(/[\*\?\[\]\{\}]/) || Pathname(value).cleanpath.to_s.start_with?("../")
        raise ArgumentError, "Worker policy requires workspace-relative paths: #{value.inspect}"
      end

      Pathname(value).cleanpath.to_s
    end

    def validate!
      raise ArgumentError, "Unknown worker write scope: #{write_scope}" unless WRITE_SCOPES.include?(write_scope)
      raise ArgumentError, "Worker permission profile name is empty" if profile_name.blank?

      if write_scope.in?(%w[tests_only scoped_changes]) && allowed_paths.empty?
        raise ArgumentError, "#{write_scope} workers require allowed paths"
      end
      if write_scope == "source_protected" && allowed_paths.any?
        raise ArgumentError, "source_protected workers cannot authorize repository paths"
      end

      real_root = root_dir.realpath
      allowed_absolute_paths.each do |path|
        unless path == root_dir || path.to_s.start_with?("#{root_dir}#{File::SEPARATOR}")
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
