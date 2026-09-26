module McpTools
  class ReadSessionPaneTool < MCP::Tool
    tool_name "read_session_pane"
    description "A snapshot of what a run's live session currently shows in its terminal pane -- what the agent is " \
      "doing right now, in its own words. This is rendered terminal output, not structured data: expect wrapping, " \
      "progress lines, and partial state. Only a live session has a pane; a finished run's result is on get_run."
    input_schema(
      properties: {
        runId: { type: "string" },
        lines: { type: "integer", description: "How many lines back to read (default 80)." }
      },
      required: %w[runId]
    )

    def self.call(runId:, server_context:, lines: 80)
      run = AdminChatAuthorization.run!(server_context:, run_id: runId)
      return ToolResponse.error("no run #{runId} in this workspace") unless run

      session = run.live_session
      return ToolResponse.error("run #{runId} has no live session") unless session

      text = Orchestrator::RunSessionRunner.snapshot(session, lines: lines.to_i.clamp(1, 500))
      return ToolResponse.error("herdr could not read the pane for run #{runId}") if text.nil?

      ToolResponse.structured(run_id: run.run_id, pane: session.herdr_pane_id, agent_status: session.agent_status, text:)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
