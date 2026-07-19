module McpTools
  class RecordRunContextEntryTool < MCP::Tool
    WRITABLE_KINDS = RunContextEntry::KINDS - [ "acceptance_criterion" ]

    tool_name "record_run_context_entry"
    description "Create or update one curated fact, constraint, rejected approach, or operator decision. Acceptance criteria are planner-owned."
    input_schema(
      properties: {
        runId: { type: "string" },
        key: { type: "string" },
        kind: { type: "string", enum: WRITABLE_KINDS },
        status: { type: "string", enum: RunContextEntry::STATUSES },
        content: { type: "string" },
        evidenceRef: { type: "string" },
        createdBy: { type: "string" }
      },
      required: %w[runId key kind status content createdBy]
    )

    def self.call(runId:, key:, kind:, status:, content:, createdBy:, server_context:, evidenceRef: nil)
      run = Run.find_or_create_for_bus!(runId)
      if kind == "acceptance_criterion" || run.run_context_entries.exists?(entry_key: key, kind: "acceptance_criterion")
        raise ArgumentError, "Acceptance criteria can only be changed by a planner decision"
      end
      entry = Orchestrator::RunContext.upsert!(
        run_id: run.run_id, entry_key: key, kind: kind, status: status,
        content: content, evidence_ref: evidenceRef, created_by: createdBy
      )
      ToolResponse.structured(entry.as_json)
    end
  end
end
