module McpTools
  class StartRunCommandTool < MCP::Tool
    tool_name "start_run_command"
    description "Start a run-scoped background command that keeps running after this worker finishes or is " \
      "replaced. Rails owns the process. Use this for anything that must still be running after your turn " \
      "(a server, a watcher) -- foreground Bash, '&', and $WORKER_LOG_PATH redirection do not survive this " \
      "worker's process group being torn down."
    input_schema(
      properties: {
        runId: { type: "string" },
        executable: { type: "string" },
        arguments: { type: "array", items: { type: "string" } },
        workingDirectory: { type: "string" },
        environment: { type: "object" },
        purpose: { type: "string" }
      },
      required: %w[runId executable]
    )

    def self.call(runId:, executable:, server_context:, arguments: [], workingDirectory: nil, environment: {}, purpose: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "start_run_command requires an authenticated worker" unless worker

      command = Orchestrator::RunCommandRunner.start(
        run: worker.run, requested_by_worker_id: worker.worker_id, executable:, arguments: Array(arguments),
        working_directory: workingDirectory, environment: environment || {}, purpose:
      )
      raise ArgumentError, command.failure_message if command.status == "failed"

      ToolResponse.structured(command.as_json)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
