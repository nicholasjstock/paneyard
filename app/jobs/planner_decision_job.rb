class PlannerDecisionJob < ApplicationJob
  queue_as :default

  def perform(id)
    record = PlannerDecision.find(id)
    return if record.status == "completed"

    record.update!(status: "running", started_at: record.started_at || Time.current, error: nil)
    model_tier = record.spawn_request.model_tier.to_sym
    result = Orchestrator::PlannerDecisionRunner.call(run: record.run, request: record.spawn_request, decision: record, model_tier:)
    apply_usage!(record, result)

    record.reload
    return if record.status.in?(%w[completed awaiting_chaperone])

    raise Orchestrator::PlannerDecisionRunner::Error, "Planner exited without submitting a decision"
  rescue => e
    record&.reload
    return if record&.status&.in?(%w[completed awaiting_chaperone])

    fail_decision!(record, e)
    raise
  end

  private

  def apply_usage!(record, result)
    usage = result[:usage] || {}
    record.with_lock do
      record.model_calls += 1
      %i[input_tokens output_tokens cache_read_input_tokens total_cost_usd].each do |key|
        record[key] = (record[key] || 0) + usage[key] if usage[key]
      end
      record.model = result[:model] if result[:model].present?
      record.cli_output = result[:cli_output] if result[:cli_output].present?
      record.save!
    end
  end

  def fail_decision!(record, error)
    return unless record

    record.update!(
      status: "failed", error: error.message, completed_at: Time.current,
      cli_output: error.try(:output).presence || record.cli_output
    )
    if Orchestrator::CapacityFailure.detected?(error.message)
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
    retry_at = Orchestrator::CapacityFailure.reset_at(error.message)
    run.update!(capacity_available_at: retry_at)
    run.publish_phase!(phase: "waiting_on_capacity", owner: "orchestrator", summary: "Planner capacity unavailable; retrying after #{retry_at.in_time_zone.strftime('%H:%M %Z')}.")
  end
end
