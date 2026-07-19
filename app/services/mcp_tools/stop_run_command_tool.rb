module McpTools
  class StopRunCommandTool < MCP::Tool
    tool_name "stop_run_command"
    description "Stop a run-scoped background command (its whole process group). Idempotent -- safe to call " \
      "again on an already-stopped command."
    input_schema(
      properties: {
        runId: { type: "string" },
        commandId: { type: "string" },
        reason: { type: "string" }
      },
      required: %w[runId commandId]
    )

    def self.call(runId:, commandId:, server_context:, reason: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "stop_run_command requires an authenticated worker" unless worker

      command = worker.run.run_commands.find_by(command_id: commandId)
      raise ArgumentError, "unknown run command: #{commandId}" unless command

      stopped = Orchestrator::RunCommandRunner.stop(command: command, reason: reason.presence || "stopped by worker")
      ToolResponse.structured(stopped.as_json)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
