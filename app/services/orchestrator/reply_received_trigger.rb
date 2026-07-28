module Orchestrator
  # Issues a ReplyReceivedReview + blocking SpawnRequest for a reply that
  # answers a run's plan-approval question -- called from
  # PullRequestResume.resume! instead of the mechanical answer path,
  # mirroring ChaperoneTrigger's shape for the other bounded review process
  # in this codebase.
  module ReplyReceivedTrigger
    module_function

    def call(question:, comment:)
      review, = ReplyReceivedReview.issue!(run: question.run, user_question: question, comment: comment)
      SpawnRequest.create!(
        run_id: question.run_id, asked_by: "github_pr_comment", requested_role: "reply_received",
        scope: review.review_id, lineage_key: review.review_id, priority: "blocking",
        text: "Classify the operator's reply to plan-approval question #{question.question_id}.",
        context: "GitHub comment ##{review.github_comment_id} from #{review.github_comment_author}: #{review.github_comment_body}",
        tags: %w[reply_received plan-approval]
      )
      review
    end
  end
end
