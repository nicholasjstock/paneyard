require "set"

class PlannerDecisionJob < ApplicationJob
  queue_as :default

  def perform(id)
    record = PlannerDecision.find(id)
    return if record.status == "completed"

    record.update!(
      status: "running", started_at: Time.current, error: nil,
      model_calls: 0, model_attempts: [], context_requests: [], context_bytes: 0,
      input_tokens: nil, output_tokens: nil, cache_read_input_tokens: nil, total_cost_usd: nil
    )
    result = decide(record)
    return if result[:chaperone_pending]

    PlannerDecision.transaction do
      Orchestrator::RunContext.apply_planner_acceptance!(
        run: record.run, criteria: Array(result[:acceptance_criteria]), updates: Array(result[:acceptance_updates])
      )
      previous_state = Orchestrator::TickState.latest(record.run_id)
      turn = Orchestrator::Turn.run_planner_turn(
        run_id: record.run_id, summary: result[:summary], next_step: result[:next_step],
        following_steps: result[:following_steps], previous_state: previous_state
      )
      Orchestrator::TickState.write(turn[:next_state])
      record.update!(
        status: "completed", decision: result.except(:usage), model: result[:model],
        completed_at: Time.current
      )
    end
    TickRunJob.perform_later
  rescue Orchestrator::PlannerDecisionRunner::Error => e
    fail_decision!(record, e)
    raise
  rescue => e
    fail_decision!(record, e)
    raise
  end

  private

  def decide(record)
    additional_context = []
    seen_requests = Set.new
    model_tier = record.spawn_request.model_tier.to_sym

    loop do
      result = Orchestrator::PlannerDecisionRunner.call(
        run: record.run, request: record.spawn_request, additional_context: additional_context, model_tier: model_tier
      )
      record_model_call!(record, result)
      if result[:outcome] == "decision"
        if record.run.run_context_entries.where(kind: "acceptance_criterion").empty? && Array(result[:acceptance_criteria]).empty?
          return queue_planner_chaperone!(record, "Small planner omitted the initial acceptance contract.") if model_tier == :small

          raise Orchestrator::PlannerDecisionRunner::Error, "Strong planner omitted the initial acceptance contract"
        end
        if result[:next_step].nil? && blocked_worker_handoff?(record)
          reason = "Small planner tried to complete the run after a worker reported blocked evidence."
          return queue_planner_chaperone!(record, reason) if model_tier == :small

          return safe_diagnosis(record, result, "Blocked worker evidence still requires a bounded next step.")
        end

        normalized = Orchestrator::StepPolicy.normalize_plan(
          next_step: result[:next_step], following_steps: result[:following_steps]
        )
        result[:next_step] = normalized[:next_step]
        result[:following_steps] = normalized[:following_steps]
        begin
          Orchestrator::StepPolicy.validate_plan!(
            run_id: record.run_id, next_step: result[:next_step], following_steps: result[:following_steps]
          )
        rescue ArgumentError => error
          if model_tier == :small
            return queue_planner_chaperone!(record, "Small planner proposed a policy-invalid plan: #{error.message}")
          end

          return safe_diagnosis(record, result, "The proposed plan violated orchestration policy: #{error.message}")
        end
      end
      if result[:outcome] == "needs_stronger_model"
        return safe_diagnosis(record, result, "The authorized strong planner could not make a bounded decision.") if model_tier == :strong

        return queue_planner_chaperone!(record, "Small planner requested stronger reasoning.")
      end
      return result unless result[:outcome] == "needs_context"

      if result[:context_request].blank?
        raise Orchestrator::PlannerDecisionRunner::Error, "Planner requested more context without naming it"
      end
      if additional_context.last && !additional_context.last[:available]
        return safe_diagnosis(record, result, "The requested context remained unavailable.")
      end
      signature = result[:context_request].slice(:source, :reference, :question, :offset, :max_chars).to_json
      unless seen_requests.add?(signature)
        raise Orchestrator::PlannerDecisionRunner::Error, "Planner repeated an identical context request without making progress"
      end

      context = Orchestrator::PlannerContextResolver.resolve(
        run: record.run, context_request: result[:context_request]
      )
      record_context_request!(record, context)
      additional_context << context

      if context[:available]
        # Promotion applies to one reasoning attempt, not the rest of the
        # decision loop. Fresh evidence gets a fresh small-model judgment;
        # it can explicitly request promotion again when genuinely needed.
        model_tier = :small
        next
      end

      return safe_diagnosis(record, result, "The requested context is unavailable.")
    end
  end

  def safe_diagnosis(record, result, reason)
    {
      outcome: "decision",
      summary: "#{reason} Diagnose the target and establish a concrete baseline before planning changes.",
      next_step: {
        owner: "worker", artifact: "initial-diagnosis.md",
        success_check: "Identify the exact target, reproduce the reported slowness, and record measured baseline evidence.",
        mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [],
        lineage_key: "#{record.run_id}:initial-performance-diagnosis"
      },
      following_steps: [], context_request: nil,
      model: result[:model], model_tier: result[:model_tier]
    }
  end

  def blocked_worker_handoff?(record)
    record.spawn_request.tags.include?("evidence-blocked")
  end

  def queue_planner_chaperone!(record, reason)
    existing = ChaperoneReview.where(
      subject_type: "planner", subject_id: record.decision_id, status: %w[queued running]
    ).first
    unless existing
      review, token = ChaperoneReview.issue!(
        run: record.run, lineage_key: "planner:#{record.decision_id}", step_attempt_ids: [],
        subject_type: "planner", subject_id: record.decision_id, summary: reason
      )
      ChaperoneReviewJob.perform_later(review.id, token)
    end
    record.update!(status: "awaiting_chaperone", error: reason)
    record.run.publish_phase!(phase: "planning", owner: "chaperone", summary: "Chaperone is reviewing whether planner promotion is justified.")
    { chaperone_pending: true }
  end

  def record_model_call!(record, result)
    usage = result[:usage] || {}
    record.with_lock do
      record.model_calls += 1
      record.model_attempts = record.model_attempts + [
        { tier: result[:model_tier], model: result[:model], input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens] }.compact
      ]
      %i[input_tokens output_tokens cache_read_input_tokens total_cost_usd].each do |key|
        record[key] = (record[key] || 0) + usage[key] if usage[key]
      end
      record.model = result[:model] if result[:model].present?
      record.save!
    end
  end

  def record_context_request!(record, context)
    metric = context.except(:content)
    record.with_lock do
      record.context_requests = record.context_requests + [ metric ]
      record.context_bytes += context[:returned_bytes]
      record.save!
    end
  end

  def fail_decision!(record, error)
    return unless record

    record.update!(status: "failed", error: error.message, completed_at: Time.current)
    if error.message.match?(/session limit|rate limit|too many requests|429/i)
      request = record.spawn_request
      request.update!(
        status: "open", fulfilled_by: nil, fulfilled_at: nil, fulfillment_note: nil, fulfilled_worker_id: nil
      )
      block_for_capacity!(record.run, error)
    else
      record.run.update!(status: "failed")
      record.run.publish_phase!(phase: "failed", owner: "orchestrator", summary: "Planner decision failed: #{error.message.first(240)}")
    end
  end

  def block_for_capacity!(run, error)
    retry_at = 30.minutes.from_now
    if (match = error.message.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\(([^)]+)\)/i))
      hour = match[1].to_i
      minute = match[2].to_i
      hour = (hour % 12) + (match[3]&.downcase == "pm" ? 12 : 0) if match[3].present?
      zone = Time.find_zone(match[4]) || Time.zone
      now = Time.current.in_time_zone(zone)
      retry_at = zone.local(now.year, now.month, now.day, hour, minute)
      retry_at += 1.day if retry_at <= Time.current
    end
    run.update!(capacity_available_at: retry_at)
    run.publish_phase!(phase: "waiting_on_capacity", owner: "orchestrator", summary: "Planner capacity unavailable; retrying after #{retry_at.in_time_zone.strftime('%H:%M %Z')}.")
  end
end
