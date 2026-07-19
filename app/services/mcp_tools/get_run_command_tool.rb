module McpTools
  class GetRunCommandTool < MCP::Tool
    tool_name "get_run_command"
    description "Get the reconciled status, exit code, and a short recent-output tail for one run-scoped background command."
    input_schema(
      properties: {
        runId: { type: "string" },
        commandId: { type: "string" }
      },
      required: %w[runId commandId]
    )

    def self.call(runId:, commandId:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "get_run_command requires an authenticated worker" unless worker

      command = worker.run.run_commands.find_by(command_id: commandId)
      raise ArgumentError, "unknown run command: #{commandId}" unless command

      Orchestrator::RunCommandRunner.reconcile!(command)
      ToolResponse.structured(command.as_json.merge(outputTail: Orchestrator::LogReader.read_tail_lines(command.log_path, 12)))
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
