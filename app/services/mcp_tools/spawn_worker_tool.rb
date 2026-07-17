module McpTools
  class SpawnWorkerTool < MCP::Tool
    tool_name "spawn_worker"
    description "Spawn one MCP-managed worker process and persist observable worker state for the run."
    input_schema(
      properties: {
        runId: { type: "string" },
        role: { type: "string", enum: %w[planner orchestrator worker infrastructure] },
        nickname: { type: "string" },
        reason: { type: "string" },
        scope: { type: "string" },
        prompt: { type: "string" }
      },
      required: %w[runId role nickname reason scope prompt]
    )

    def self.call(runId:, role:, nickname:, reason:, scope:, prompt:, server_context:)
      run = Run.find_or_create_for_bus!(runId)
      worker = Orchestrator::WorkerSpawner.spawn_worker(run: run, role: role, nickname: nickname, reason: reason, scope: scope, prompt: prompt)
      ToolResponse.structured(worker.as_json)
    end
  end
end
