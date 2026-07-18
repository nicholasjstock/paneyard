module Orchestrator
  module ApplyChaperoneDecision
    module_function

    def call(review:, action:, summary:)
      raise ArgumentError, "Unknown chaperone action" unless ChaperoneReview::ACTIONS.include?(action)

      return apply_planner_decision(review:, action:, summary:) if review.subject_type == "planner"

      attempt = StepAttempt.where(attempt_id: review.step_attempt_ids).order(:created_at).last!
      source = attempt.spawn_request
      ChaperoneReview.transaction do
        case action
        when "continue_small", "promote"
          SpawnRequest.create!(
            run_id: review.run_id, asked_by: "chaperone", scope: source.scope, text: source.text,
            context: "Chaperone #{action}: #{summary}", requested_role: source.requested_role,
            priority: "blocking", tags: source.tags + [ "chaperone", action ],
            lineage_key: review.lineage_key, model_tier: action == "promote" ? "strong" : "small"
          )
        when "stop"
          UserQuestion.create!(
            run_id: review.run_id, asked_by: "chaperone", scope: source.scope,
            text: diagnosis_stop_question,
            context: stop_question_context(review:, summary:), priority: "blocking",
            tags: %w[chaperone stopped]
          )
          review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: summary)
        end
        review.update!(status: "completed", action:, summary:, completed_at: Time.current)
        StepAttempt.where(attempt_id: review.step_attempt_ids).update_all(
          chaperone_status: "completed", chaperone_action: action, chaperone_summary: summary
        )
      end
      TickRunJob.perform_later
    end

    def apply_planner_decision(review:, action:, summary:)
      decision = PlannerDecision.find_by!(decision_id: review.subject_id)
      request = decision.spawn_request
      ChaperoneReview.transaction do
        case action
        when "continue_small", "promote"
          request.update!(
            status: "open", fulfilled_by: nil, fulfilled_at: nil, fulfillment_note: nil,
            fulfilled_worker_id: nil, model_tier: action == "promote" ? "strong" : "small",
            context: [ request.context, "Chaperone #{action}: #{summary}" ].compact.join(" ")
          )
          decision.update!(status: "failed", error: "Chaperone requested a new #{request.model_tier} planner attempt.", completed_at: Time.current)
        when "stop"
          decision.update!(status: "failed", error: "Chaperone stopped planner promotion: #{summary}", completed_at: Time.current)
          UserQuestion.create!(
            run_id: review.run_id, asked_by: "chaperone", scope: request.scope,
            text: planner_stop_question,
            context: stop_question_context(review:, summary:), priority: "blocking",
            tags: %w[chaperone planner stopped]
          )
          review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: summary)
        end
        review.update!(status: "completed", action:, summary:, completed_at: Time.current)
      end
      TickRunJob.perform_later
    end
    private_class_method :apply_planner_decision

    def diagnosis_stop_question
      "Should this run stop here, retry diagnosis within its current scope, or use a different bounded approach?"
    end
    private_class_method :diagnosis_stop_question

    def planner_stop_question
      "Should this run stop here, retry within its current scope, or expand to the protected work the planner proposed?"
    end
    private_class_method :planner_stop_question

    def stop_question_context(review:, summary:)
      trigger = review.trigger_reason.presence
      [ "Chaperone conclusion: #{summary}", ("Trigger: #{trigger}" if trigger) ].compact.join("\n\n")
    end
    private_class_method :stop_question_context
  end
end
