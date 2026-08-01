module McpTools
  class RecordWorkspaceEnvVarTool < MCP::Tool
    tool_name "record_workspace_env_var"
    description "Persist an environment variable this workspace's commands need (e.g. a bundle install workaround) " \
      "so every future worker and start_run_command in this workspace gets it automatically, instead of every " \
      "future worker rediscovering the same workaround. Recording the same name again overwrites its value. " \
      "Do not use this for secrets you would not want visible in this workspace's stored configuration."
    input_schema(
      properties: {
        runId: { type: "string" },
        name: { type: "string" },
        value: { type: "string" },
        evidenceRef: { type: "string" }
      },
      required: %w[runId name value evidenceRef]
    )

    def self.call(runId:, name:, value:, evidenceRef:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      entry = Orchestrator::WorkspaceEnvVars.record!(
        run_id: runId, name: name, value: value, evidence_ref: evidenceRef, recorded_by: worker&.role || "unknown"
      )
      ToolResponse.structured(entry.as_json)
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
