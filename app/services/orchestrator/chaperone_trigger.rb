module Orchestrator
  module ChaperoneTrigger
    module_function

    THRESHOLD = 2

    def call(attempt)
      criterion_ids = AcceptanceCriterionStep
        .where(run_id: attempt.run_id, lineage_key: attempt.lineage_key)
        .distinct.pluck(:acceptance_criterion_id)
      return trigger_for_lineage(attempt) if criterion_ids.empty?

      AcceptanceCriterion.where(id: criterion_ids).find_each do |criterion|
        review = trigger_for_criterion(attempt:, criterion:)
        return review if review
      end
      nil
    end

    def trigger_for_lineage(attempt)
      failures = StepAttempt.where(
        run_id: attempt.run_id, lineage_key: attempt.lineage_key,
        mode: attempt.mode, outcome: %w[blocked failed]
      ).order(:created_at)
      issue(attempt:, lineage_key: attempt.lineage_key, failures:)
    end
    private_class_method :trigger_for_lineage

    # Groups failures by acceptance criterion rather than lineage_key. The
    # planner is free to mint a new lineage_key on every retry of what is
    # conceptually the same blocked objective (see TODO.md), but the
    # AcceptanceCriterionStep provenance edge it writes on every dispatch
    # (AcceptanceCriteria.record_step!) always points back to the same,
    # immutable criterion key regardless of how the retry was renamed.
    # Deliberately spans mode -- a run can churn on one criterion through
    # diagnosis, recording, and infrastructure attempts alike.
    def trigger_for_criterion(attempt:, criterion:)
      lineage_keys = AcceptanceCriterionStep
        .where(run_id: attempt.run_id, acceptance_criterion_id: criterion.id)
        .distinct.pluck(:lineage_key)
      failures = StepAttempt
        .where(run_id: attempt.run_id, lineage_key: lineage_keys, outcome: %w[blocked failed])
        .order(:created_at)
      issue(attempt:, lineage_key: "criterion:#{criterion.key}", failures:)
    end
    private_class_method :trigger_for_criterion

    def issue(attempt:, lineage_key:, failures:)
      return if failures.count < THRESHOLD
      return if ChaperoneReview.where(run_id: attempt.run_id, lineage_key:, status: %w[queued running]).exists?

      review, = ChaperoneReview.issue!(
        run: attempt.run, lineage_key:, step_attempt_ids: failures.pluck(:attempt_id)
      )
      attempt.update!(chaperone_status: "queued")
      SpawnRequest.create!(
        requested_role: "chaperone", run_id: attempt.run_id, scope: review.lineage_key,
        lineage_key: review.lineage_key, model_tier: "strong", priority: "blocking",
        asked_by: "chaperone",
        text: review.trigger_reason.presence || review.summary.presence || "Chaperone review for lineage #{review.lineage_key}."
      )
      review
    end
    private_class_method :issue
  end
end
