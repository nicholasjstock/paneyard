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

      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "reply_received", requested_role: "planner", priority: "blocking",
        scope: Turn::PLANNER_FOLLOWUP_SCOPE,
        text: "The operator approved the pending plan. Proceed with the next bounded step.",
        context: "Plan-approval question #{question.question_id} approved: #{summary}",
        tags: %w[github reply_received resume]
      )
      run.publish_phase!(phase: "planning", owner: "reply_received", summary: "Operator approved the plan.")
    end
    private_class_method :apply_approved!

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
