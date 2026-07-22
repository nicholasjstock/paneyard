module McpTools
  class RecordProtectedPathsTool < MCP::Tool
    tool_name "record_protected_paths"
    description "Declare this workspace's source roots that are protected by default and writable only during implementation. " \
      "Use [\".\"] for the complete source worktree. Only callable by an authenticated project_init worker. " \
      "Replaces any previously declared roots for this workspace."
    input_schema(
      properties: {
        runId: { type: "string" },
        patterns: {
          type: "array", minItems: 1, maxItems: 30,
          items: { type: "string" }
        }
      },
      required: %w[runId patterns]
    )

    def self.call(runId:, patterns:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "record_protected_paths requires an authenticated project_init worker" unless worker.nil? || worker.role == "project_init"

      run = Run.find_by!(run_id: runId)
      cleaned = patterns.map(&:to_s).map(&:strip).reject(&:blank?).uniq
      run.workspace.update!(protected_path_patterns: cleaned)
      ToolResponse.structured(patterns: run.workspace.protected_path_patterns)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
