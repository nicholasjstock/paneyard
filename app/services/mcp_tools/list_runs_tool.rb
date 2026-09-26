module McpTools
  class ListRunsTool < MCP::Tool
    tool_name "list_runs"
    description "List this workspace's runs, newest first, with enough state to answer \"what is happening right " \
      "now\" -- status, which agent, whether a session is live and what it is doing, branch, and pull request. " \
      "Defaults to runs that are still in flight; pass includeFinished for recent history too."
    input_schema(
      properties: {
        includeFinished: { type: "boolean", description: "Include completed, failed, and stopped runs." },
        limit: { type: "integer", description: "Maximum runs to return (default 20)." }
      },
      required: []
    )

    def self.call(server_context:, includeFinished: false, limit: 20)
      chat = AdminChatAuthorization.chat!(server_context:)
      scope = chat ? chat.workspace.runs : Run.all
      scope = scope.active unless includeFinished
      runs = scope.order(created_at: :desc).limit(limit.to_i.clamp(1, 100)).includes(:run_sessions)

      ToolResponse.structured(
        capacity: {
          limit: Orchestrator::RunConcurrency.limit,
          in_flight: Orchestrator::RunConcurrency.in_flight
        },
        runs: runs.map { |run| RunPresenter.summary(run) }
      )
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
