module McpTools
  class ReportFailedApproachTool < MCP::Tool
    tool_name "report_failed_approach"
    description "Report that something you tried failed, in your own words: what you tried and what happened. " \
      "Call this whenever an approach fails, not only in your final worker_turn report -- it becomes a candidate " \
      "lesson for later reconciliation into durable project memory."
    input_schema(
      properties: {
        runId: { type: "string" },
        approach: { type: "string" },
        reason: { type: "string" },
        nextApproach: { type: "string" }
      },
      required: %w[runId approach reason]
    )

    def self.call(runId:, approach:, reason:, server_context:, nextApproach: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "report_failed_approach requires an authenticated worker" unless worker

      request = SpawnRequest.find_by(fulfilled_worker_id: worker.worker_id)
      lineage_key = request&.lineage_key.presence || request&.scope || worker.scope

      candidate = MemoryCandidate.create!(
        run_id: runId, worker_id: worker.worker_id, lineage_key: lineage_key, role: worker.role,
        approach: approach, reason: reason, next_approach: nextApproach
      )
      ToolResponse.structured(candidate.as_json)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
