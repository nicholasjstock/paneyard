module Orchestrator
  module FinalizationRecovery
    module_function

    DEMO_SCOPE = "demo-notes.md"

    def applicable?(attempt)
      attempt.spawn_request.requested_role == "demo" && attempt.spawn_request.scope == DEMO_SCOPE
    end

    def call(attempt)
      run = attempt.run
      run.update!(publication_status: "demo_blocked", publication_error: attempt.result.to_s.truncate(1_000))
      review = ChaperoneTrigger.call(attempt)
      return review if review

      SpawnRequest.create!(run_id: run.run_id, asked_by: "finalization_recovery", requested_role: "demo", priority: "blocking", scope: DEMO_SCOPE, execution_mode: "recording", write_scope: "source_protected", text: "Retry the blocked demo stage. Read the prior command log and verify a serving server before completing.")
      run.publish_phase!(phase: "committing", owner: "orchestrator", summary: "Retrying the blocked demo stage before publication.")
      :requeued
    end

    def paused?(run)
      run.publication_status == "demo_blocked"
    end

    def resume_after_repair?(run:, role:)
      return false unless paused?(run) && role.in?(%w[worker infrastructure])

      # The fixed finalization guard treats any completed demo row as a
      # finished stage. Clear only that stage so TickRunJob resumes demo,
      # never the earlier seeder/reporter/curator stages or product planning.
      Worker.where(run_id: run.run_id, role: "demo", scope: DEMO_SCOPE).update_all(handoff_completed_at: nil)
      run.update!(publication_status: "commit_pending", publication_error: nil)
      true
    end
  end
end
