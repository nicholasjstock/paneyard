module McpTools
  class RecordProjectMemoryEntryTool < MCP::Tool
    tool_name "record_project_memory_entry"
    description "Record durable knowledge about this workspace's project, so future runs in it start already " \
      "knowing. A new entry with the same key supersedes the prior one and must cite evidenceRef. Record what a " \
      "future run would waste time rediscovering -- an architectural constraint, a convention, a hazard you hit -- " \
      "not what this run happened to change."
    input_schema(
      properties: {
        runId: { type: "string" },
        key: { type: "string" },
        kind: { type: "string", enum: WorkspaceMemoryEntry::KINDS },
        content: { type: "string" },
        evidenceRef: { type: "string" }
      },
      required: %w[runId key kind content evidenceRef]
    )

    def self.call(runId:, key:, kind:, content:, evidenceRef:, server_context:)
      SessionAuthorization.session!(server_context:, run_id: runId)
      entry = Orchestrator::ProjectMemory.record!(
        run_id: runId, entry_key: key, kind: kind, content: content,
        evidence_ref: evidenceRef, recorded_by: "session"
      )
      ToolResponse.structured(entry.as_json)
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
