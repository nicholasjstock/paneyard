module Orchestrator
  # Applies the reply_received persona's classification of an operator
  # reply to a run's plan-approval question. Mirrors ApplyChaperoneDecision's
  # shape: a bounded review's one decision drives Rails state, never the
  # review itself touching source, acceptance criteria, or next_step.
  module ApplyReplyReceivedDecision
    module_function

    GRANTED_TAG = "granted"

    def call(review:, action:, summary:, explanation: nil)
      raise ArgumentError, "Unknown reply_received action" unless ReplyReceivedReview::ACTIONS.include?(action)
      raise ArgumentError, "explain requires an explanation" if action == "explain" && explanation.blank?

      question = review.user_question
      run = review.run

      ReplyReceivedReview.transaction do
        case action
        when "approved" then apply_approved!(run:, question:, review:, summary:)
        when "explain" then apply_explain!(run:, question:, review:, explanation:)
        when "revise" then apply_revise!(run:, question:, review:, summary:)
        end
        review.update!(status: "completed", action:, summary:, completed_at: Time.current)
      end
      TickRunJob.perform_later
    end

    def apply_approved!(run:, question:, review:, summary:)
      question.update!(
        status: "answered", answered_by: "reply_received", answered_at: Time.current,
        answer_text: review.github_comment_body, tags: (question.tags + [ GRANTED_TAG ]).uniq
      )

      # Same reconciliation PullRequestResume.resume! performs on an ordinary
      # answered-and-unblocked run: a published run's branch may have
      # drifted from main since the PR opened, and this is cheap/idempotent
      # regardless of what actually changed.
      if run.pull_request_url.present?
        Orchestrator::RunPublication.queue_worker!(run)
      else
        run.update!(publication_status: "resume_requested")
      end

      dispatch_gated_step!(run:, question:, summary:)
      run.publish_phase!(phase: "planning", owner: "reply_received", summary: "Operator approved the plan.")
    end
    private_class_method :apply_approved!

    # PlanApprovalQuestion stores the exact first writable handoff because
    # that handoff is deliberately suppressed while the operator question is
    # open. Approval must dispatch this durable plan directly; asking a fresh
    # planner to reconstruct it can skip its head and select a following step.
    def dispatch_gated_step!(run:, question:, summary:)
      next_step = Orchestrator::TickState.deep_symbolize(question.gated_next_step).presence
      raise ArgumentError, "Plan-approval question #{question.question_id} has no gated next step" unless next_step

      following_steps = Array(question.gated_following_steps).map { |step| Orchestrator::TickState.deep_symbolize(step) }
      turn = Turn.run_planner_turn(
        run_id: run.run_id,
        summary: "Operator approved the gated plan: #{summary}",
        next_step:, following_steps:, previous_state: TickState.latest(run.run_id), record_step: false
      )
      TickState.write(turn.fetch(:next_state))
    end
    private_class_method :dispatch_gated_step!

    def apply_explain!(run:, question:, review:, explanation:)
      question.update!(status: "answered", answered_by: "reply_received", answered_at: Time.current, answer_text: review.github_comment_body)

      UserQuestion.create!(
        run_id: run.run_id, asked_by: "reply_received", priority: "blocking", scope: question.scope,
        text: "#{explanation}\n\nDoes this resolve it? Reply `approved` to continue, or reply with a further correction.",
        context: question.context, tags: [ Orchestrator::PlanApprovalQuestion::TAG ]
      )
      run.publish_phase!(phase: "awaiting_user_feedback", owner: "reply_received", summary: "Explained the pending plan; awaiting operator approval.")
    end
    private_class_method :apply_explain!

    def apply_revise!(run:, question:, review:, summary:)
      question.update!(status: "answered", answered_by: "reply_received", answered_at: Time.current, answer_text: review.github_comment_body)

      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "reply_received", requested_role: "planner", priority: "blocking",
        scope: Turn::PLANNER_FOLLOWUP_SCOPE,
        text: "The operator's reply to the plan-approval question identified a real problem with the pending plan, " \
          "not merely a question about it. Revise the next bounded step to address it. The revised step will go " \
          "back through the same plan-approval gate before any code is written.",
        context: "Plan-approval objection: #{summary}",
        tags: %w[planner reply_received revise]
      )
      run.publish_phase!(phase: "planning", owner: "reply_received", summary: "Plan-approval objection sent back to the planner: #{summary}")
    end
    private_class_method :apply_revise!
  end
end
