module McpTools
  class ChaperoneStateTool < MCP::Tool
    tool_name "get_chaperone_state"
    description "Read the run-scoped attempts and compact workflow state authorized for this chaperone review."
    input_schema(properties: {})

    def self.call(server_context:)
      review = ChaperoneReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      attempts = StepAttempt.where(attempt_id: review.step_attempt_ids).order(:created_at)
      planner_decision = review.subject_type == "planner" && PlannerDecision.find_by(decision_id: review.subject_id)
      artifacts = Orchestrator::ArtifactStore.collect(
        review.run.target_root, review.run_id, attempts.map { |attempt| attempt.spawn_request.scope }.uniq
      )[:artifacts]
      ToolResponse.structured(
        review: {
          id: review.review_id, lineageKey: review.lineage_key, subjectType: review.subject_type,
          purpose: review.subject_type == "planner" ? "Assess whether a strong planner retry is justified" : "Assess repeated diagnosis progress",
          trigger: review.trigger_reason || review.summary
        },
        objective: { task: review.run.task, phase: review.run.phase, summary: review.run.phase_summary },
        acceptance: {
          blockers: Orchestrator::AcceptanceCriteria.completion_blockers(run_id: review.run_id),
          tree: Orchestrator::AcceptanceCriteria.tree(run_id: review.run_id),
          brief: Orchestrator::RunContext.snapshot(run_id: review.run_id)[:entries]
        },
        attempts: attempts.each_with_index.map { |attempt, index| attempt_summary(attempt, index + 1) },
        priorBlockers: prior_blockers(review),
        plannerAttempt: planner_decision && {
          status: planner_decision.status, model: planner_decision.model,
          modelAttempts: planner_decision.model_attempts, contextRequests: planner_decision.context_requests,
          error: planner_decision.error
        },
        artifacts: artifacts.map { |artifact| artifact.slice(:name, :exists, :size_bytes, :updated_at, :preview) },
        recentTransitions: Orchestrator::TickState.history(review.run_id, limit: 5)[:entries]
      )
    end

    # Every prior "stop" replan for this lineage, oldest first, so a repeat
    # of the identical blocker under new wording gets recognized and reused
    # instead of minting a fresh blockerKey that dodges the exhaustion guard
    # (Orchestrator::ApplyChaperoneDecision.bounded_replan_already_requested?
    # matches on exact key).
    def self.prior_blockers(review)
      SpawnRequest.where(
        run_id: review.run_id, asked_by: "chaperone", requested_role: "planner", lineage_key: review.lineage_key
      ).where("tags LIKE ?", "%stopped_retry%").order(:created_at).filter_map do |request|
        key = request.tags.find { |tag| tag.start_with?("blocker:") }&.delete_prefix("blocker:")
        next unless key

        { blockerKey: key, tier: request.model_tier, requestedAt: request.created_at.iso8601(3), summary: request.context.first(400) }
      end
    end

    def self.attempt_summary(attempt, number)
      request = attempt.spawn_request
      worker = Worker.find_by(worker_id: attempt.worker_id)
      {
        attempt: number, outcome: attempt.outcome, result: attempt.result.first(2_000),
        evidenceOutcome: attempt.evidence_outcome, evidenceCitations: attempt.evidence_citations,
        artifact: request.scope, assignment: request.text.first(1_200), model: worker&.model,
        startedAt: worker&.started_at&.iso8601(3), stoppedAt: worker&.stopped_at&.iso8601(3)
      }
    end
    private_class_method :attempt_summary
  end
end
