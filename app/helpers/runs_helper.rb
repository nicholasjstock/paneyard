module RunsHelper
  def planner_decision_trigger(decision)
    request = decision.spawn_request
    return "Initial launch" if request.tags.include?("launch")
    return "Recovery request" if request.tags.any? { |tag| tag.match?(/recover|stalled|dead-end/) }

    "#{request.asked_by} handoff"
  end

  def planner_decision_route(decision)
    return "Failed before a decision" if decision.status == "failed"
    return "Waiting for chaperone" if decision.status == "awaiting_chaperone"

    step = decision.decision&.dig("next_step")
    return "Run completion" if decision.status == "completed" && step.blank?
    return "Decision pending" if step.blank?

    [ step["owner"], step["artifact"] ].compact.join(" → ")
  end

  def planner_decision_models(decision)
    models = decision.attempts.map do |attempt|
      [ attempt.model_tier, attempt.model ].compact.join(": ")
    end
    models = decision.model_attempts.map { |attempt| [ attempt["tier"], attempt["model"] ].compact.join(": ") } if models.empty?
    models.reject(&:blank?).join(" → ").presence || "no model call"
  end

  def planner_decision_duration(decision)
    return "not started" unless decision.started_at

    distance_of_time_in_words(decision.started_at, decision.completed_at || Time.current)
  end

  def planner_step_title(step)
    [ step["owner"], step["artifact"] ].compact.join(" → ").presence || "No worker step"
  end

  def planner_decision_error_summary(decision)
    error = decision.error.to_s
    json_start = error.index("{")
    if json_start
      payload = JSON.parse(error[json_start..])
      return payload["result"] if payload["result"].present?
    end

    error.truncate(240)
  rescue JSON::ParserError
    error.truncate(240)
  end
end
