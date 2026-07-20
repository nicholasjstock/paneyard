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
