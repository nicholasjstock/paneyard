module McpTools
  class ReadRunCommandLogTool < MCP::Tool
    tool_name "read_run_command_log"
    description "Read a bounded window of a run command's combined stdout/stderr log, by byte offset. Never " \
      "returns the whole log -- follow next_cursor to read forward instead of re-reading from the start."
    input_schema(
      properties: {
        runId: { type: "string" },
        commandId: { type: "string" },
        offset: { type: "integer" },
        maxBytes: { type: "integer" }
      },
      required: %w[runId commandId]
    )

    def self.call(runId:, commandId:, server_context:, offset: 0, maxBytes: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "read_run_command_log requires an authenticated worker" unless worker

      command = worker.run.run_commands.find_by(command_id: commandId)
      raise ArgumentError, "unknown run command: #{commandId}" unless command

      window = Orchestrator::RunCommandRunner.read_log_window(
        command, offset: offset || 0, limit: maxBytes || Orchestrator::RunCommandRunner::DEFAULT_LOG_READ_LIMIT
      )
      ToolResponse.structured(window)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
