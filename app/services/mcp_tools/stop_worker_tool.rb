module McpTools
  class StopWorkerTool < MCP::Tool
    tool_name "stop_worker"
    description "Stop one MCP-managed worker by workerId or nickname and persist the stop reason."
    input_schema(
      properties: {
        workerId: { type: "string" },
        nickname: { type: "string" },
        reason: { type: "string" }
      },
      required: %w[reason]
    )

    def self.call(reason:, server_context:, workerId: nil, nickname: nil)
      raise ArgumentError, "stop_worker requires workerId or nickname" if workerId.blank? && nickname.blank?

      worker = workerId.present? ? Worker.find_by!(worker_id: workerId) : Worker.find_by!(nickname: nickname)
      stopped = Orchestrator::WorkerSpawner.stop_worker(worker: worker, reason: reason)
      ToolResponse.structured(stopped.as_json)
    end
  end
end
