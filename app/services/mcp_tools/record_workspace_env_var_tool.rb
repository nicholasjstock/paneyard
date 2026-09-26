module McpTools
  class RecordWorkspaceEnvVarTool < MCP::Tool
    tool_name "record_workspace_env_var"
    description "Persist an environment variable this workspace's commands need (e.g. a bundle install workaround) " \
      "so every future worker and start_run_command in this workspace gets it automatically, instead of every " \
      "future worker rediscovering the same workaround. Recording the same name again overwrites its value. " \
      "value is set directly as a literal process environment variable -- it is never passed through a shell, so " \
      "it must already be a fully resolved value (e.g. an absolute path like /tmp/bundler_gems), not shell syntax " \
      "like $TMPDIR/bundler_gems or `command`, which would reach the next process as that exact unexpanded literal " \
      "string. Do not use this for secrets you would not want visible in this workspace's stored configuration."
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
      session = SessionAuthorization.session!(server_context:, run_id: runId)
      entry = Orchestrator::WorkspaceEnvVars.record!(
        run_id: runId, name: name, value: value, evidence_ref: evidenceRef,
        recorded_by: session&.driver || "session"
      )
      ToolResponse.structured(entry.as_json)
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
