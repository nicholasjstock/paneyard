module McpTools
  # Passes a message the operator asked for on to another run's live session
  # (Orchestrator::SessionMessage), so the operator need not copy and paste
  # between panes.
  #
  # On both endpoints. From /mcp/admin (the operator's own client, their
  # lobby) workspace is required, as for queue_run. A run session may only
  # reach the other runs of its own workspace, and never itself.
  #
  # It is a relay for what the operator asked to send, not a channel for
  # agents to start conversations with each other: steering a session stays
  # the operator's business (AGENTS.md, "Sessions, Not Orchestration").
  class SendSessionMessageTool < MCP::Tool
    tool_name "send_session_message"
    description "Type a message into another run's live agent session, as its own input, through herdr. Use it " \
      "only when the operator asks you to pass something on to that run (\"send run X this finding\"); never to " \
      "start a conversation with another session on your own. It is refused when the run has no live session, " \
      "is still starting, or its agent is waiting at a permission prompt. A busy agent gets it as input typed " \
      "while it works. submitted: true means herdr accepted the input, not that the agent has read or acted on " \
      "it; its answer, if any, comes in that run's own reports (get_run). The message arrives after a line " \
      "naming who sent it. From a run, only other runs in your own workspace; from outside a run, workspace " \
      "is required."
    input_schema(
      properties: {
        runId: { type: "string", description: "The run whose session receives the message." },
        message: {
          type: "string",
          description: "The text to send, at most #{Orchestrator::SessionMessage::MAX_LENGTH} characters. " \
            "Make it stand on its own: the recipient has none of your context."
        },
        workspace: { type: "string", description: "Workspace name the run belongs to." }
      },
      required: %w[runId message]
    )

    def self.call(runId:, message:, server_context:, workspace: nil)
      from_run = sending_run(server_context)
      if from_run && workspace.present? && workspace != from_run.workspace.name
        raise ArgumentError, "a run session may only message runs in its own workspace (#{from_run.workspace.name.inspect})"
      end

      resolved = WorkspaceResolution.resolve!(server_context:, workspace:, explicit: true)
      run = resolved.runs.find_by(run_id: runId) || raise(ArgumentError, "no run #{runId} in workspace #{resolved.name.inspect}")
      sent = Orchestrator::SessionMessage.call(run, message, from_run:)

      ToolResponse.structured(
        submitted: true, run_id: sent.fetch(:run_id), agent_status: sent.fetch(:agent_status),
        note: "herdr accepted the input; that is not confirmation the agent has read or acted on it"
      )
    rescue ArgumentError, Orchestrator::SessionMessage::Refused => error
      ToolResponse.error(error.message)
    end

    # The calling run on /mcp/run, whose endpoint puts its authenticated
    # session in the context; nil on /mcp/admin, whose context is empty.
    def self.sending_run(server_context)
      return nil unless server_context.respond_to?(:[]) && server_context[:run_session_id].present?

      SessionAuthorization.session!(server_context:).run
    end
    private_class_method :sending_run
  end
end
