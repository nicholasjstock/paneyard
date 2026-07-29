module McpTools
  class FinalizeRunPublicationTool < MCP::Tool
    tool_name "finalize_run_publication"
    description "Report the terminal outcome of this run's commit/rebase/push sequence. Rails owns GitHub publication " \
      "(creating or updating the pull request, issue linkage, and reviewer question) from this call. Only the terminal " \
      "git worker may call it, exactly once."
    input_schema(
      properties: {
        runId: { type: "string" },
        outcome: { type: "string", enum: %w[published no_changes failed] },
        error: { type: "string" }
      },
      required: %w[runId outcome]
    )

    def self.call(runId:, outcome:, server_context:, error: nil)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "finalize_run_publication requires an authenticated git worker" unless worker&.role == "git"
      run = Run.find_by!(run_id: runId)
      result = Orchestrator::RunPublication.finalize!(
        run, outcome:, error:
      )
      Worker.mark_handoff_completed!(run_id: runId, role: "git")
      ToolResponse.structured(outcome: result, publication_status: run.reload.publication_status)
    rescue ArgumentError, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, Orchestrator::RunPublication::Error => e
      ToolResponse.error(e.message)
    end
  end
end
