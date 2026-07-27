module McpTools
  class FinalizeRunPublicationTool < MCP::Tool
    tool_name "finalize_run_publication"
    description "Report the terminal outcome of this run's commit/rebase/push/PR sequence, which you performed " \
      "yourself with real git access. Rails persists run state and opens the reviewer question from this call -- " \
      "it does not re-run any git command on your behalf. Only the terminal git worker may call it, exactly once."
    input_schema(
      properties: {
        runId: { type: "string" },
        outcome: { type: "string", enum: %w[published no_changes failed] },
        pullRequestUrl: { type: "string" },
        error: { type: "string" },
        reviewAssets: {
          type: "array",
          items: {
            type: "object",
            properties: { workspacePath: { type: "string" }, githubUrl: { type: "string" } },
            required: %w[workspacePath githubUrl]
          }
        }
      },
      required: %w[runId outcome]
    )

    def self.call(runId:, outcome:, server_context:, pullRequestUrl: nil, error: nil, reviewAssets: [])
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "finalize_run_publication requires an authenticated git worker" unless worker&.role == "git"
      raise ArgumentError, "finalize_run_publication requires pullRequestUrl for outcome=published" if outcome == "published" && pullRequestUrl.blank?

      run = Run.find_by!(run_id: runId)
      result = Orchestrator::RunPublication.finalize!(
        run, outcome:, pull_request_url: pullRequestUrl, error:, review_assets: Array(reviewAssets)
      )
      Worker.mark_handoff_completed!(run_id: runId, role: "git")
      ToolResponse.structured(outcome: result, publication_status: run.reload.publication_status)
    rescue ArgumentError, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, Orchestrator::RunPublication::Error => e
      ToolResponse.error(e.message)
    end
  end
end
