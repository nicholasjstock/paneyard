module McpTools
  class ReadRunPromptTool < MCP::Tool
    tool_name "read_run_prompt"
    description "The exact prompt a run's session was given -- the whole briefing, including the workspace memory " \
      "and working agreement prepended to the operator's task. Use it to answer \"why is it doing that\": if a run " \
      "went somewhere unexpected, what it was actually told is usually the answer."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      run = AdminChatAuthorization.run!(server_context:, run_id: runId)
      return ToolResponse.error("no run #{runId} in this workspace") unless run

      session = run.latest_session
      # Fall back to composing it: a queued run has no session yet, and a run
      # whose prompt file was cleaned up should still be explicable.
      prompt =
        if session&.prompt_path.present? && File.exist?(session.prompt_path)
          File.read(session.prompt_path)
        else
          Orchestrator::RunPrompt.compose(run:, session_driver: run.launcher_variant)
        end

      ToolResponse.structured(
        run_id: run.run_id,
        source: session&.prompt_path.present? && File.exist?(session.prompt_path) ? "as_sent" : "recomposed",
        prompt: prompt
      )
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
