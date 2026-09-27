module McpTools
  class RecordWorkspaceEnvVarTool < MCP::Tool
    tool_name "record_workspace_env_var"
    description "Save an environment variable that commands in this workspace need (e.g. a bundler workaround) " \
      "so every future job in this workspace starts with it. It does not change your current session -- export " \
      "it yourself as well. Recording a name again overwrites it. The value is set literally, never through a " \
      "shell: pass a resolved value such as /tmp/bundler_gems, not $TMPDIR/bundler_gems or `cmd`. It is stored " \
      "in plain text and injected into every future session, so never record a secret."
    input_schema(
      properties: {
        runId: { type: "string", description: "This run's id, from your startup prompt." },
        name: { type: "string" },
        value: { type: "string" },
        evidenceRef: { type: "string", description: "One line on why it is needed, e.g. the failing command and its error." }
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
