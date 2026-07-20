module Orchestrator
  # Called live, mid-turn, from McpTools::SubmitPlannerDecisionTool -- this is
  # where every outcome PlannerDecisionJob#decide used to handle post-hoc (after
  # a separate CLI process exited) now happens instead, while the model that
  # proposed it is still reasoning in the same conversation. A rejected
  # "decision" outcome is returned as data (accepted: false), not raised, so
  # the model can read the exact reason and correct itself within its own
  # turn instead of Rails escalating straight to chaperone on the first
  # mistake. MAX_REJECTED_DECISION_ATTEMPTS bounds that self-correction so a
  # model that cannot converge still reaches the existing chaperone/safe
  # diagnosis backstop, rather than looping indefinitely.
  module PlannerDecisionSubmission
    module_function

    MAX_REJECTED_DECISION_ATTEMPTS = 3

    def call(decision:, params:)
      return { accepted: true } if decision.status.in?(%w[completed awaiting_chaperone])

      model_tier = decision.spawn_request.model_tier.to_sym
      attempt = create_attempt!(decision, params, model_tier)

      case params[:outcome]
      when "decision"
        handle_decision(decision:, params:, attempt:, model_tier:)
      when "needs_stronger_model"
        handle_needs_stronger_model(decision:, attempt:, model_tier:)
      when "needs_context"
        handle_needs_context(decision:, params:, attempt:)
      else
        reject_attempt!(attempt, "Unknown outcome: #{params[:outcome]}")
        { accepted: false, error: "Unknown outcome: #{params[:outcome]}" }
      end
    end

    def handle_decision(decision:, params:, attempt:, model_tier:)
      existing_contract = decision.run.acceptance_criteria.roots.exists?
      if existing_contract
        # New top-level (parentKey-less) criteria can't be added once the
        # contract exists -- silently drop only those, same leniency the
        # flat model always had. A parentKey'd entry is a legitimate
        # decomposition of an existing criterion and passes through untouched.
        new_roots, decompositions = Array(params[:acceptance_criteria]).partition { |c| c[:parent_key].blank? }
        if new_roots.any?
          attempt.update!(rejection_reason: "Ignored acceptanceCriteria because the run contract is already established")
          params[:acceptance_criteria] = decompositions
        end
      end
      if !existing_contract && Array(params[:acceptance_criteria]).empty?
        return reject_decision!(decision:, attempt:, model_tier:, reason: "Initial planner decision omitted the acceptance contract")
      end
      if params[:next_step].nil? && blocked_worker_handoff?(decision)
        reason = "Cannot complete the run: a worker reported blocked evidence. Propose a bounded next step instead of stopping."
        return reject_decision!(decision:, attempt:, model_tier:, reason:)
      end

      normalized = StepPolicy.normalize_plan(next_step: params[:next_step], following_steps: params[:following_steps])
      params[:next_step] = normalized[:next_step]
      params[:following_steps] = normalized[:following_steps]
      # Criteria proposed in *this* call aren't persisted until persist_decision!
      # runs (after validation succeeds), so a step in this same call referencing
      # the contract it just proposed would otherwise fail with "unknown
      # criteria" -- pass the union of what's already saved and what's being
      # proposed right now.
      acceptance_criteria_keys = (
        AcceptanceCriteria.current_keys(run_id: decision.run_id) + Array(params[:acceptance_criteria]).map { |c| c[:key].to_s }
      ).uniq
      begin
        StepPolicy.validate_plan!(
          run_id: decision.run_id, next_step: params[:next_step], following_steps: params[:following_steps],
          acceptance_criteria_keys:
        )
      rescue ArgumentError => error
        return reject_decision!(decision:, attempt:, model_tier:, reason: error.message)
      end

      attempt.update!(disposition: "accepted")
      persist_decision!(decision:, params:)
      { accepted: true }
    end
    private_class_method :handle_decision

    # Bounded self-correction: a rejected "decision" is returned as data so
    # the model can retry, up to MAX_REJECTED_DECISION_ATTEMPTS total
    # rejections for this PlannerDecision -- past that, fall back to the
    # same backstop the immediate-escalation path used before (chaperone for
    # the small tier, safe_diagnosis for the strong tier, since there is no
    # stronger tier left to promote to).
    def reject_decision!(decision:, attempt:, model_tier:, reason:)
      reject_attempt!(attempt, reason)
      rejected_count = decision.attempts.where(outcome: "decision", disposition: "rejected").count
      return { accepted: false, error: reason } if rejected_count < MAX_REJECTED_DECISION_ATTEMPTS

      give_up_reason = "#{reason} (after #{rejected_count} rejected attempts)"
      if model_tier == :small
        queue_chaperone!(decision, give_up_reason)
      else
        persist_safe_diagnosis!(decision, give_up_reason)
      end
      { accepted: true, escalated: true }
    end
    private_class_method :reject_decision!

    def handle_needs_stronger_model(decision:, attempt:, model_tier:)
      attempt.update!(disposition: "needs_chaperone")
      if model_tier == :strong
        persist_safe_diagnosis!(decision, "The authorized strong planner could not make a bounded decision.")
      else
        queue_chaperone!(decision, "Small planner requested stronger reasoning.")
      end
      { accepted: true }
    end
    private_class_method :handle_needs_stronger_model

    def handle_needs_context(decision:, params:, attempt:)
      attempt.update!(disposition: "needs_context")

      last_request = decision.context_requests.last&.deep_stringify_keys
      if last_request && last_request["available"] == false
        persist_safe_diagnosis!(decision, "The requested context remained unavailable.")
        return { accepted: true, escalated: true }
      end
      if params[:context_request].blank?
        reject_attempt!(attempt, "Requested more context without naming it")
        return { accepted: false, error: "contextRequest is required when outcome=needs_context" }
      end

      # Compare on stringified keys throughout: a freshly-authenticated tool
      # call always loads `decision` fresh from the DB (JSON columns
      # round-trip to string keys), but callers exercising this service
      # in-process against the same long-lived object (e.g. specs) would
      # otherwise still hold the symbol-keyed hash this same request just
      # appended -- normalize both sides so the comparison is correct either way.
      # Offset is also normalized the same way PlannerContextResolver.resolve
      # normalizes it (nil -> 0, "first window"), since that's what actually
      # gets persisted into context_requests -- comparing the raw incoming
      # nil against the persisted 0 would never match.
      signature = params[:context_request]
        .slice(:source, :reference, :question, :offset, :max_chars)
        .merge(offset: params[:context_request][:offset].to_i)
        .deep_stringify_keys.to_json
      already_seen = decision.context_requests.any? do |seen|
        seen.deep_stringify_keys.slice("source", "reference", "question", "offset", "max_chars").to_json == signature
      end
      if already_seen
        reject_attempt!(attempt, "Repeated an identical context request without making progress")
        return {
          accepted: false,
          error: "That exact context request was already made and cannot add information -- try a different source, reference, or offset."
        }
      end

      context = PlannerContextResolver.resolve(run: decision.run, context_request: params[:context_request])
      record_context_request!(decision, context)
      unless context[:available]
        persist_safe_diagnosis!(decision, "The requested context is unavailable.")
        return { accepted: true, escalated: true }
      end

      { accepted: true, context: context }
    end
    private_class_method :handle_needs_context

    def blocked_worker_handoff?(decision)
      decision.spawn_request.tags.include?("evidence-blocked")
    end
    private_class_method :blocked_worker_handoff?

    def queue_chaperone!(decision, reason)
      existing = ChaperoneReview.where(subject_type: "planner", subject_id: decision.decision_id, status: %w[queued running]).first
      unless existing
        review, = ChaperoneReview.issue!(
          run: decision.run, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [],
          subject_type: "planner", subject_id: decision.decision_id, summary: reason
        )
        SpawnRequest.create!(
          requested_role: "chaperone", run_id: decision.run_id, scope: review.lineage_key,
          lineage_key: review.lineage_key, model_tier: "strong", priority: "blocking",
          asked_by: "chaperone", text: review.trigger_reason.presence || review.summary.presence || reason
        )
      end
      decision.update!(status: "awaiting_chaperone", error: reason)
      decision.run.publish_phase!(phase: "planning", owner: "chaperone", summary: "Chaperone is reviewing whether planner promotion is justified.")
    end
    private_class_method :queue_chaperone!

    def persist_safe_diagnosis!(decision, reason)
      persist_decision!(
        decision:,
        params: {
          summary: "#{reason} Diagnose the target and establish a concrete baseline before planning changes.",
          next_step: {
            owner: "worker", artifact: "initial-diagnosis.md",
            success_check: "Identify the exact target, reproduce the reported behavior, and record concrete baseline evidence.",
            mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [],
            lineage_key: "#{decision.run_id}:initial-diagnosis",
            addresses_criteria: AcceptanceCriteria.current_keys(run_id: decision.run_id)
          },
          following_steps: []
        }
      )
    end
    private_class_method :persist_safe_diagnosis!

    def persist_decision!(decision:, params:)
      PlannerDecision.transaction do
        AcceptanceCriteria.apply!(
          run: decision.run, criteria: Array(params[:acceptance_criteria]), updates: Array(params[:acceptance_updates])
        )
        AcceptanceCriteria.record_step!(run: decision.run, next_step: params[:next_step])
        previous_state = TickState.latest(decision.run_id)
        turn = Turn.run_planner_turn(
          run_id: decision.run_id, summary: params[:summary], next_step: params[:next_step],
          following_steps: params[:following_steps], previous_state: previous_state
        )
        TickState.write(turn[:next_state])
        decision.update!(status: "completed", decision: params, completed_at: Time.current)
      end
      TickRunJob.perform_later
    end
    private_class_method :persist_decision!

    def create_attempt!(decision, params, model_tier)
      decision.with_lock do
        decision.attempts.create!(
          sequence: (decision.attempts.maximum(:sequence) || 0) + 1,
          model_tier: model_tier.to_s,
          outcome: params[:outcome].presence || "decision",
          disposition: "proposed",
          proposal: params
        )
      end
    end
    private_class_method :create_attempt!

    def reject_attempt!(attempt, reason)
      attempt.update!(disposition: "rejected", rejection_reason: reason)
    end
    private_class_method :reject_attempt!

    def record_context_request!(decision, context)
      metric = context.except(:content)
      decision.with_lock do
        decision.context_requests = decision.context_requests + [ metric ]
        decision.context_bytes += context[:returned_bytes]
        decision.save!
      end
    end
    private_class_method :record_context_request!
  end
end
