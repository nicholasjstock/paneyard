module Orchestrator
  class WorkerExecutionPolicy
    BASE_CLAUDE_TOOLS = %w[Bash Read Grep Glob ToolSearch].freeze
    WRITING_CLAUDE_TOOLS = %w[Edit Write].freeze

    WRITE_SCOPES = %w[source_protected tests_only scoped_changes].freeze

    attr_reader :root_dir, :mode, :write_scope, :allowed_paths, :protected_patterns, :profile_name

    def initialize(root_dir:, mode:, write_scope:, allowed_paths:, protected_patterns: [], profile_name: "worker")
      @root_dir = Pathname(root_dir).expand_path
      @mode = mode.to_s
      @write_scope = write_scope.to_s
      @allowed_paths = Array(allowed_paths).map { |path| normalize_path(path) }.uniq
      @protected_patterns = Array(protected_patterns).map { |path| normalize_path(path) }.uniq
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
        allowed_write_roots.each do |root|
          path = claude_absolute_path(root_dir.join(root))
          suffix = literal_allowed_root?(root) ? "" : "/**"
          allow_rules << "Edit(#{path}#{suffix})"
          allow_rules << "Write(#{path}#{suffix})"
        end
      end
      scratch_writable_absolute_paths.each do |path|
        suffix = path.directory? ? "/**" : ""
        allow_rules << "Edit(#{claude_absolute_path(path)}#{suffix})"
        allow_rules << "Write(#{claude_absolute_path(path)}#{suffix})"
      end

      {
        "permissions" => { "allow" => allow_rules },
        "sandbox" => {
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => { "allowWrite" => (allowed_absolute_paths + scratch_writable_absolute_paths).map(&:to_s) }
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
    # scratch_writable_relative_paths grants everything that isn't declared
    # source regardless of write_scope (see its comment for why this replaced
    # a git-status-based cache heuristic).
    def codex_config_overrides
      filesystem = {
        ":minimal" => "read",
        ":tmpdir" => "write",
        ":root" => "read",
        ":workspace_roots" => { "." => "read" }
          .merge(allowed_write_roots.index_with { "write" })
          .merge(scratch_writable_relative_paths.index_with { "write" })
      }

      [
        toml_assignment("default_permissions", profile_name),
        toml_assignment("permissions.#{profile_name}.filesystem", filesystem),
        toml_assignment("permissions.#{profile_name}.network", { "enabled" => true })
      ]
    end

    def allowed_absolute_paths
      @allowed_absolute_paths ||= allowed_write_roots.map { |path| root_dir.join(path).cleanpath }
    end

    # Sandboxes accept concrete filesystem roots, not globs. A protected
    # pattern such as app/**/*.rb therefore grants its non-glob prefix (app),
    # which permits newly-created source files too while still excluding
    # unrelated roots such as node_modules or build output.
    def allowed_write_roots
      @allowed_write_roots ||= allowed_paths.map { |pattern| glob_root(pattern) }.uniq
    end

    # A pattern with no glob characters names one exact path (typically a
    # single file) rather than a directory to recurse into -- `Edit(file/**)`
    # would never match the file itself, since nothing can exist "inside" a
    # file. A root can be reached by more than one pattern; treat it as
    # recursive if any of them actually was a glob.
    def literal_allowed_root?(root)
      allowed_paths.select { |pattern| glob_root(pattern) == root }.none? { |pattern| pattern.match?(/[*?\[{]/) }
    end

    def scratch_writable_absolute_paths
      @scratch_writable_absolute_paths ||= scratch_writable_relative_paths.map { |path| root_dir.join(path).cleanpath }
    end

    # Replaces a prior git-status-based heuristic (walk `git ls-files
    # --others --ignored --directory` for wholesale-ignored cache dirs) that
    # could never grant Rails' own log/tmp/storage: those directories carry a
    # tracked .keep file precisely so they survive a fresh checkout, which
    # means git never reports them as a fully-ignored *directory* (only
    # individual ignored files inside them, once those files already exist)
    # -- so a brand-new worktree's worker could never create log/test.log or
    # open storage/test.sqlite3 in the first place. protected_patterns (the
    # workspace's declared source/config/test globs, see
    # Workspace#protected_write_patterns) is the authoritative, always-known
    # answer instead: anything NOT under a protected root is scratch, whether
    # or not a file has ever been written there yet. .git is excluded
    # unconditionally -- protected_patterns describes source, not
    # infrastructure, and record_protected_paths_tool's own validation
    # actually forbids declaring .git as protected, so it must be handled
    # here or it would otherwise fall through as "not source" and become
    # writable.
    def scratch_writable_relative_paths
      @scratch_writable_relative_paths ||= begin
        protected_roots = protected_patterns.map { |pattern| glob_root(pattern) }.uniq
        # No declared protected patterns means we don't yet know what's
        # source -- fail closed (nothing is scratch) rather than open.
        protected_roots = [ "." ] if protected_roots.empty?
        writable_complement(root_dir, protected_roots.map { |root| root_dir.join(root).cleanpath } + [ root_dir.join(".git") ])
          .map { |path| path.relative_path_from(root_dir).to_s }
      end
    end

    private

    # Recursively grants everything under `dir` except subtrees rooted at
    # `protected`: a directory with nothing protected inside or above it is
    # granted wholesale (including files/subdirectories created later, since
    # callers turn this into a `<path>/**` rule); otherwise we descend into
    # its existing children to carve the protected subtree back out.
    def writable_complement(dir, protected)
      return [] if protected.any? { |path| path == dir }
      overlaps_protected = protected.any? do |path|
        path.to_s.start_with?("#{dir}#{File::SEPARATOR}") || dir.to_s.start_with?("#{path}#{File::SEPARATOR}")
      end
      return [ dir ] unless overlaps_protected
      return [] unless dir.directory?

      dir.children.flat_map { |child| writable_complement(child, protected) }
    end

    def normalize_path(path)
      value = path.to_s
      if value.blank? || Pathname(value).absolute? || Pathname(value).cleanpath.to_s.start_with?("../")
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

    def glob_root(pattern)
      prefix = pattern.to_s.split(/[\*\?\[\{]/, 2).first.to_s.delete_suffix("/")
      prefix.presence || "."
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
