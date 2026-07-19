module Orchestrator
  module ChaperoneTrigger
    module_function

    def call(attempt)
      failures = StepAttempt.where(
        run_id: attempt.run_id, lineage_key: attempt.lineage_key,
        mode: attempt.mode, outcome: %w[blocked failed]
      ).order(:created_at)
      return if failures.count < 2
      return if ChaperoneReview.where(run_id: attempt.run_id, lineage_key: attempt.lineage_key, status: %w[queued running]).exists?

      review, token = ChaperoneReview.issue!(
        run: attempt.run, lineage_key: attempt.lineage_key, step_attempt_ids: failures.pluck(:attempt_id)
      )
      attempt.update!(chaperone_status: "queued")
      ChaperoneReviewJob.perform_later(review.id, token)
      review
    end
  end
end
