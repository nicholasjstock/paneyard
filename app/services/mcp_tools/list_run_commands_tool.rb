module McpTools
  class ListRunCommandsTool < MCP::Tool
    tool_name "list_run_commands"
    description "List run-scoped background commands for a run, most recent first. Check this before starting " \
      "a new server or watcher to avoid duplicates."
    input_schema(
      properties: {
        runId: { type: "string" },
        status: { type: "string", enum: RunCommand::STATUSES }
      },
      required: %w[runId]
    )

    LIMIT = 50

    def self.call(runId:, server_context:, status: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "list_run_commands requires an authenticated worker" unless worker

      scope = worker.run.run_commands.order(started_at: :desc, created_at: :desc).limit(LIMIT)
      scope = scope.where(status: status) if status.present?
      commands = scope.to_a
      commands.select(&:active?).each { |command| Orchestrator::RunCommandRunner.reconcile!(command) }

      ToolResponse.structured(commands: commands.map(&:as_json))
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
