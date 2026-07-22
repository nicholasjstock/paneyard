module McpTools
  class RecordProjectSetupTool < MCP::Tool
    tool_name "record_project_setup"
    description "Record durable findings about how to run this project's local development environment. Only " \
      "callable by an authenticated project_init worker. Include one finding with key " \
      "\"#{Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY}\" describing exactly how to start the full dev environment."
    input_schema(
      properties: {
        runId: { type: "string" },
        findings: {
          type: "array", minItems: 1, maxItems: 5,
          items: {
            type: "object", additionalProperties: false,
            properties: {
              key: { type: "string" },
              content: { type: "string" },
              evidenceRef: { type: "string" }
            },
            required: %w[key content evidenceRef]
          }
        }
      },
      required: %w[runId findings]
    )

    def self.call(runId:, findings:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "record_project_setup requires an authenticated project_init worker" unless worker.nil? || worker.role == "project_init"

      entries = findings.map do |finding|
        finding = finding.symbolize_keys
        Orchestrator::ProjectMemory.record!(
          run_id: runId, entry_key: finding.fetch(:key), kind: "operational_rule",
          content: finding.fetch(:content), evidence_ref: finding.fetch(:evidenceRef), recorded_by: "project_init"
        )
      end
      ToolResponse.structured(entries: entries.map(&:as_json))
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
