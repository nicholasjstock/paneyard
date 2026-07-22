module McpTools
  class WriteScopedFileTool < MCP::Tool
    tool_name "write_scoped_file"
    description "Replace one workspace file inside an implementation worker's authorized source roots. Unavailable to source-protected workers."
    input_schema(
      properties: {
        runId: { type: "string" },
        path: { type: "string" },
        content: { type: "string" }
      },
      required: %w[runId path content]
    )

    def self.call(runId:, path:, content:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "write_scoped_file requires an authenticated worker" unless worker
      unless worker.write_scope.in?(%w[scoped_changes tests_only])
        raise ArgumentError, "#{worker.write_scope || 'unknown'} workers cannot modify workspace files"
      end
      raise ArgumentError, "path is not authorized for this worker: #{path}" unless authorized_path?(worker, path)

      target = authorized_target(worker.run.target_root, path)
      File.binwrite(target, content)
      ToolResponse.structured(path:, bytes: content.bytesize)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end

    def self.authorized_target(root, path)
      raise ArgumentError, "path must be workspace-relative" if Pathname.new(path).absolute?

      clean_root = Pathname.new(root).realpath
      target = clean_root.join(path).cleanpath
      raise ArgumentError, "path escapes the workspace" unless target.to_s.start_with?("#{clean_root}/")
      raise ArgumentError, "parent directory does not exist" unless target.dirname.exist?
      raise ArgumentError, "symlink targets are not writable" if target.symlink?
      raise ArgumentError, "parent directory escapes the workspace" unless target.dirname.realpath.to_s.start_with?(clean_root.to_s)

      target.to_s
    end
    private_class_method :authorized_target

    def self.authorized_path?(worker, path)
      normalized = Pathname(path).cleanpath.to_s
      worker.allowed_paths.any? do |pattern|
        File.fnmatch?(pattern, normalized, File::FNM_PATHNAME) ||
          (pattern.end_with?("/**") && normalized.start_with?("#{pattern.delete_suffix('/**')}/"))
      end
    rescue ArgumentError
      false
    end
    private_class_method :authorized_path?
  end
end
