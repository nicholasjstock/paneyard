module McpTools
  class JobFinishedTool < MCP::Tool
    tool_name "job_finished"
    description "Finish your own job only when the operator explicitly asks to end or close the job/session, after all requested work succeeds. " \
      "Verifies the branch tip and clean worktree are merged into your base branch or fully pushed to the actual remote, then closes your session/workspace and safely reclaims the worktree " \
      "after acknowledging this call. Does not commit, push or merge. Use report_idle for ordinary pauses or review. " \
      "Retries are accepted while your capability is live; after closure it returns HTTP 401."
    input_schema(properties: { summary: { type: "string", description: "Final Markdown report of the requested work, merge or push verification, and PR URL when one was requested." } }, required: [ "summary" ])

    def self.call(summary:, server_context:)
      session = SessionAuthorization.session!(server_context:)
      raise ArgumentError, "authenticated live run session required" unless session

      Orchestrator::JobFinalization.request!(session, summary:)
      response = ToolResponse.structured(run_id: session.run.run_id, finalization: "accepted")
      server_context[:job_finalization_acknowledgment]&.store(:accepted, true)
      response
    rescue ArgumentError, Orchestrator::Runner::Error => error
      ToolResponse.error(error.message)
    end
  end
end
