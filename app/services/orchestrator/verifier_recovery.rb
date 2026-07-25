module Orchestrator
  # A dead verifier must be retried by re-requesting a real verifier-role
  # spawn, never through planner recovery: StepPolicy::PLANNER_STEP_OWNERS
  # deliberately excludes "verifier" (verification stays Rails-triggered and
  # independent), so a planner asked to retry verification can only dispatch
  # a worker-role stand-in that submit_acceptance_verification correctly
  # rejects. Observed live in run-20260724-120458-4780: dead verifier ->
  # planner recovery -> worker-role retry -> "Authentication role mismatch"
  # -> chaperone -> stopped for user input -- every hop after the verifier
  # died was spend on a problem Rails can fix mechanically by re-invoking
  # AcceptanceCriteria.request_verification!.
  #
  # Bounded: repeated verifier failures escalate to this mechanism's own
  # blocking user question (same shape as ApplyChaperoneDecision's stop
  # path, so it publishes to the run's PR conversation like every other
  # operator question) instead of respawning verifiers forever.
  module VerifierRecovery
    module_function

    LINEAGE_PREFIX = "acceptance:"
    MAX_VERIFIER_ATTEMPTS = 3

    def applicable?(attempt)
      attempt.lineage_key.to_s.start_with?(LINEAGE_PREFIX) || verification_criterion_for(attempt).present?
    end

    # Returns :requeued or :escalated when this module owned the recovery,
    # or delegates to ChaperoneTrigger (returning its review or nil) when
    # the criterion is no longer awaiting verification -- in that state a
    # failure in this lineage is not a verification-dispatch problem, so
    # the normal escalation path applies.
    def call(attempt)
      criterion = verification_criterion_for(attempt)
      return ChaperoneTrigger.call(attempt) unless criterion

      recover!(run: attempt.run, criterion:)
    end

    # Resolves which criterion's verification a failed attempt belongs to.
    # The "acceptance:<key>" lineage covers every Rails-minted verifier
    # request, but a planner names its own steps' lineages freely -- the
    # same renaming problem ChaperoneTrigger already solves via the
    # AcceptanceCriterionStep provenance edge written on every planner
    # dispatch (Turn.run_planner_turn -> AcceptanceCriteria.record_step!).
    # A step failing while its addressed criterion sits at
    # ready_for_verification is verification churn regardless of what the
    # planner called it: implementation was already declared complete with
    # evidence, so the only work left for that criterion is verification.
    def verification_criterion_for(attempt)
      run = attempt.run
      lineage = attempt.lineage_key.to_s
      if lineage.start_with?(LINEAGE_PREFIX)
        criterion = run.acceptance_criteria.find_by(key: lineage.delete_prefix(LINEAGE_PREFIX))
        return criterion&.status == "ready_for_verification" ? criterion : nil
      end

      criterion_ids = AcceptanceCriterionStep
        .where(run_id: run.run_id, lineage_key: lineage)
        .distinct.pluck(:acceptance_criterion_id)
      return nil if criterion_ids.empty?

      run.acceptance_criteria.where(id: criterion_ids, status: "ready_for_verification").order(:id).first
    end

    # Dead-end safety net for TickRunJob: a criterion stuck awaiting
    # verification with no live verifier and no open verifier request is
    # re-armed here instead of handing recovery to a planner that cannot
    # legally dispatch one. Covers the paths that never record a
    # StepAttempt at all (e.g. a verifier killed by a capacity limit).
    def requeue_stalled_verification!(run)
      handled = false
      run.acceptance_criteria.where(status: "ready_for_verification").find_each do |criterion|
        scope = "acceptance-verify-#{criterion.key}"
        next if Worker.exists?(run_id: run.run_id, status: "running", role: "verifier", scope:)
        next if SpawnRequest.exists?(run_id: run.run_id, requested_role: "verifier", scope:, status: "open")

        recover!(run:, criterion:)
        handled = true
      end
      handled
    end

    def recover!(run:, criterion:)
      failures = verification_failure_count(run:, criterion:)
      if failures >= MAX_VERIFIER_ATTEMPTS
        escalate!(run:, criterion:, failures:)
        :escalated
      else
        requeue!(run:, criterion:)
        :requeued
      end
    end
    private_class_method :recover!

    # Counts every failed verification attempt for this criterion, however
    # its lineage was named: the canonical acceptance:<key> lineage plus any
    # planner-renamed lineage linked back via provenance edges. Restricted
    # to verification-mode attempts on the provenance side so the
    # criterion's earlier implementation/diagnosis churn (which legitimately
    # shares those lineages) doesn't consume the verifier retry budget.
    def verification_failure_count(run:, criterion:)
      linked_lineages = AcceptanceCriterionStep
        .where(run_id: run.run_id, acceptance_criterion_id: criterion.id)
        .distinct.pluck(:lineage_key)
      failures = StepAttempt.where(run_id: run.run_id, outcome: %w[blocked failed])
      failures.where(lineage_key: "#{LINEAGE_PREFIX}#{criterion.key}")
        .or(failures.where(lineage_key: linked_lineages, mode: "verification"))
        .count
    end
    private_class_method :verification_failure_count

    # The retry carries corrective context for the dominant observed
    # failure mode (run-20260724-120458-4780's verifier): the model located
    # its deferred MCP tools by keyword but never loaded them with a
    # full-name select, then narrated the submission as text and exited.
    # With session resume, the retry continues that same conversation, so
    # this context lands as direct feedback on its own false claim.
    RETRY_CONTEXT =
      "A previous verifier attempt for this criterion ended without actually invoking " \
      "submit_acceptance_verification -- no submission was recorded, regardless of what its final message " \
      "claimed. The tool's full registered name is mcp__workflow__submit_acceptance_verification; if your " \
      "MCP tools are deferred, load them with ToolSearch using full prefixed names " \
      "(query select:mcp__workflow__submit_acceptance_verification) before use. Narrating a tool call in " \
      "text does not execute it.".freeze

    def requeue!(run:, criterion:)
      scope = "acceptance-verify-#{criterion.key}"
      unless SpawnRequest.exists?(run_id: run.run_id, requested_role: "verifier", scope:, status: "open")
        AcceptanceCriteria.request_verification!(run:, criterion:, context: RETRY_CONTEXT)
      end
      run.publish_phase!(
        phase: "planning", owner: "orchestrator",
        summary: "Verifier attempt for #{criterion.key} did not complete; Rails re-requested independent verification."
      )
    end
    private_class_method :requeue!

    def escalate!(run:, criterion:, failures:)
      unless run.open_blocking_question?
        UserQuestion.create!(
          run_id: run.run_id, asked_by: "verifier_recovery", scope: "acceptance-verify-#{criterion.key}",
          text: "Independent verification of acceptance criterion \"#{criterion.key}\" has failed #{failures} times " \
            "without a conclusive submission. Should verification be retried again, the criterion waived, or the run stopped?",
          context: "Criterion: #{criterion.content} Candidate evidence: #{criterion.evidence_ref}. " \
            "Each verifier attempt ended without submitting a verdict via submit_acceptance_verification.",
          priority: "blocking", tags: %w[verifier_recovery verification]
        )
      end
      run.publish_phase!(
        phase: "awaiting_user_feedback", owner: "orchestrator",
        summary: "Verification of #{criterion.key} failed #{failures} attempts; waiting for operator guidance."
      )
    end
    private_class_method :escalate!
  end
end
