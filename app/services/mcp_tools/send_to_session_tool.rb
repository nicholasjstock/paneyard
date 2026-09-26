module McpTools
  class SendToSessionTool < MCP::Tool
    tool_name "send_to_session"
    description "Type a message into a run's live session, exactly as if the operator had typed it into that pane. " \
      "This is how you steer work that is already underway -- answer a question the agent is blocked on, redirect " \
      "it, or tell it to stop what it is doing and do something else. The session sees it as live input mid-task, " \
      "so write it as an instruction to someone already working, not as a fresh briefing."
    input_schema(
      properties: {
        runId: { type: "string" },
        message: { type: "string" }
      },
      required: %w[runId message]
    )

    def self.call(runId:, message:, server_context:)
      raise ArgumentError, "message is required" if message.blank?

      run = AdminChatAuthorization.run!(server_context:, run_id: runId)
      return ToolResponse.error("no run #{runId} in this workspace") unless run

      session = run.live_session
      return ToolResponse.error("run #{runId} has no live session to send to") unless session

      Orchestrator::RunSessionRunner.prompt!(session, message)
      BusEvent.publish("run.operator_message", run_id: run.run_id, payload: {
        runId: run.run_id, via: "admin_chat", message:
      })

      ToolResponse.structured(run_id: run.run_id, delivered: true, agent_status: session.reload.agent_status)
    rescue ArgumentError, Orchestrator::RunSessionRunner::Error, Orchestrator::Herdr::Error => error
      ToolResponse.error(error.message)
    end
  end
end
