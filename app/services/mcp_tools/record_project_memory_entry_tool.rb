module McpTools
  class RecordProjectMemoryEntryTool < MCP::Tool
    tool_name "record_project_memory_entry"
    description "Record durable target-project knowledge for a run's workspace. Only planners and operators may call this. A new entry with the same key supersedes the prior entry and must cite evidenceRef."
    input_schema(
      properties: {
        runId: { type: "string" },
        key: { type: "string" },
        kind: { type: "string", enum: WorkspaceMemoryEntry::KINDS },
        content: { type: "string" },
        evidenceRef: { type: "string" },
        recordedBy: { type: "string", enum: WorkspaceMemoryEntry::RECORDERS }
      },
      required: %w[runId key kind content evidenceRef recordedBy]
    )

    def self.call(runId:, key:, kind:, content:, evidenceRef:, recordedBy:, server_context:)
      entry = Orchestrator::ProjectMemory.record!(
        run_id: runId, entry_key: key, kind: kind, content: content,
        evidence_ref: evidenceRef, recorded_by: recordedBy
      )
      ToolResponse.structured(entry.as_json)
    end
  end
end
