module Orchestrator
  # Issues a ReplyReceivedReview + blocking SpawnRequest for a reply to a
  # plan-approval or pull-request-review question. The bounded review decides
  # whether it is approval, a request for explanation, or a revision before
  # Rails changes the run's publication state.
  module ReplyReceivedTrigger
    module_function

    def call(question:, comment:)
      resume_completed_pull_request_review!(question.run) if pull_request_review_question?(question)
      review, = ReplyReceivedReview.issue!(run: question.run, user_question: question, comment: comment)
      SpawnRequest.create!(
        run_id: question.run_id, asked_by: "github_pr_comment", requested_role: "reply_received",
        scope: review.review_id, lineage_key: review.review_id, priority: "blocking",
        text: "Classify the operator's reply to #{question_kind(question)} question #{question.question_id}.",
        context: "GitHub comment ##{review.github_comment_id} from #{review.github_comment_author}: #{review.github_comment_body}",
        tags: [ "reply_received", question_kind(question).tr("_", "-") ]
      )
      review
    end

    def question_kind(question)
      question.scope == "pull_request_review" ? "pull_request_review" : "plan_approval"
    end
    private_class_method :question_kind

    def pull_request_review_question?(question)
      question.scope == "pull_request_review"
    end
    private_class_method :pull_request_review_question?

    # TickRunJob only processes running runs and finalizes immediately when
    # TickState still says completed. A new reply review on an already-published
    # PR must therefore revive both records before its request can be spawned.
    def resume_completed_pull_request_review!(run)
      return unless run.status == "completed"

      run.update!(status: "running", stopped_at: nil, publication_status: "resume_requested")
      previous = TickState.latest(run.run_id)
      return unless previous[:phase] == "completed"

      TickState.write(
        previous.merge(
          phase: "planning", tick_count: previous.fetch(:tick_count) + 1,
          last_plan_summary: "Pull-request review reply received; awaiting reply classification.",
          pending_spawn_keys: [], following_steps: [], last_stall_finding: nil
        )
      )
    end
    private_class_method :resume_completed_pull_request_review!
  end
end
