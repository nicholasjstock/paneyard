module McpTools
  class RecordTestPathsTool < MCP::Tool
    tool_name "record_test_paths"
    description "Record workspace-relative test directories discovered during project setup. These directories are automatically writable for implementation workers. Only callable by an authenticated project_init worker."
    input_schema(
      properties: {
        runId: { type: "string" },
        paths: { type: "array", maxItems: 20, items: { type: "string" } }
      },
      required: %w[runId paths]
    )

    def self.call(runId:, paths:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "record_test_paths requires an authenticated project_init worker" unless worker.nil? || worker.role == "project_init"

      run = Run.find_by!(run_id: runId)
      roots = paths.map { |path| normalize_path(path) }.uniq
      roots.each { |path| validate_directory!(run.workspace, path) }
      run.workspace.update!(test_path_patterns: roots)
      ToolResponse.structured(paths: run.workspace.test_path_patterns)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    def self.normalize_path(path)
      value = path.to_s.strip
      raise ArgumentError, "test path must be a workspace-relative directory" if value.blank? || Pathname(value).absolute? || value.in?(%w[. ..]) || value.match?(/[\\*?\[\]{}]/)

      normalized = Pathname(value).cleanpath.to_s
      raise ArgumentError, "test path escapes the workspace" if normalized.start_with?("../")

      normalized
    end
    private_class_method :normalize_path

    def self.validate_directory!(workspace, path)
      root = Pathname(workspace.source_root).expand_path
      candidate = root.join(path).cleanpath
      raise ArgumentError, "test path escapes the workspace" unless candidate.to_s.start_with?("#{root}/")
      raise ArgumentError, "test path is not an existing directory: #{path}" unless candidate.directory?
    end
    private_class_method :validate_directory!
  end
end
