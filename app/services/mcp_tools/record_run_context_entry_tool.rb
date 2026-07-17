module McpTools
  class RecordRunContextEntryTool < MCP::Tool
    tool_name "record_run_context_entry"
    description "Create or update one curated run-context entry. Use stable keys. Verified acceptance criteria and confirmed facts require an evidenceRef."
    input_schema(
      properties: {
        runId: { type: "string" },
        key: { type: "string" },
        kind: { type: "string", enum: RunContextEntry::KINDS },
        status: { type: "string", enum: RunContextEntry::STATUSES },
        content: { type: "string" },
        evidenceRef: { type: "string" },
        createdBy: { type: "string" }
      },
      required: %w[runId key kind status content createdBy]
    )

    def self.call(runId:, key:, kind:, status:, content:, createdBy:, server_context:, evidenceRef: nil)
      run = Run.find_or_create_for_bus!(runId)
      entry = Orchestrator::RunContext.upsert!(
        run_id: run.run_id, entry_key: key, kind: kind, status: status,
        content: content, evidence_ref: evidenceRef, created_by: createdBy
      )
      ToolResponse.structured(entry.as_json)
    end
  end
end
