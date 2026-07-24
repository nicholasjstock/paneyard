module Orchestrator
  # Shared read/write for OrchestratorTick -- one row per tick serves as
  # both "current state" and "history entry" (see OrchestratorTick's own
  # comment). Snake_case throughout, matching the model's own attribute
  # names directly; camelizing for the wire only happens at each MCP
  # tool's McpTools::ToolResponse.structured call.
  module TickState
    module_function

    DEFAULT_HISTORY_LIMIT = 5
    MAX_HISTORY_LIMIT = 50
    HISTORY_SUMMARY_LIMIT = 600

    def write(state)
      state = deep_symbolize(state)
      run = Run.find_or_create_for_bus!(state[:run_id])
      tick = OrchestratorTick.find_or_initialize_by(run_id: run.run_id, tick_count: state[:tick_count])
      tick.assign_attributes(
        phase: state[:phase],
        last_plan_summary: state[:last_plan_summary],
        pending_spawn_keys: state[:pending_spawn_keys] || [],
        following_steps: (state[:following_steps] || []).map { |step| deep_symbolize(step) },
        last_stall_finding: state[:last_stall_finding]
      )
      tick.save!
      sync_run_phase!(run: run, state: state)
      to_state(tick)
    end

    def latest(run_id)
      tick = OrchestratorTick.for_run(run_id).last
      tick ? to_state(tick) : default_state(run_id)
    end

    def history(run_id, limit: DEFAULT_HISTORY_LIMIT, include_details: false)
      scope = OrchestratorTick.for_run(run_id)
      total_ticks = scope.count
      ticks = scope.reorder(tick_count: :desc).limit(limit.to_i.clamp(1, MAX_HISTORY_LIMIT)).to_a.reverse

      {
        run_id: run_id,
        history_mode: include_details ? "detailed" : "compact",
        total_ticks: total_ticks,
        entries: ticks.map { |tick| include_details ? to_state(tick) : to_history_entry(tick) }
      }
    end

    def default_state(run_id)
      {
        run_id: run_id,
        phase: "starting",
        tick_count: 0,
        last_plan_summary: nil,
        pending_spawn_keys: [],
        following_steps: [],
        last_stall_finding: nil,
        last_updated_at: nil
      }
    end

    def to_state(tick)
      {
        run_id: tick.run_id,
        phase: tick.phase,
        tick_count: tick.tick_count,
        last_plan_summary: tick.last_plan_summary,
        pending_spawn_keys: tick.pending_spawn_keys,
        following_steps: deep_symbolize(tick.following_steps),
        last_stall_finding: tick.last_stall_finding,
        last_updated_at: tick.created_at&.iso8601(3)
      }
    end

    def to_history_entry(tick)
      {
        run_id: tick.run_id,
        phase: tick.phase,
        tick_count: tick.tick_count,
        last_plan_summary: truncate(tick.last_plan_summary),
        pending_spawn_count: tick.pending_spawn_keys.size,
        following_step_count: tick.following_steps.size,
        last_stall_finding: truncate(tick.last_stall_finding),
        last_updated_at: tick.created_at&.iso8601(3)
      }
    end

    def truncate(value)
      text = value.to_s
      text.length > HISTORY_SUMMARY_LIMIT ? "#{text.first(HISTORY_SUMMARY_LIMIT).rstrip}…" : text
    end

    # OrchestratorTick#following_steps round-trips through a JSON column as
    # string-keyed hashes -- deep-symbolizing at this boundary means
    # callers never have to care whether a step came fresh from
    # Orchestrator::Planner/Turn or back out of the database.
    def deep_symbolize(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array
        value.map { |v| deep_symbolize(v) }
      else
        value
      end
    end

    def sync_run_phase!(run:, state:)
      phase = state[:phase]
      owner = infer_phase_owner(phase)
      summary = summarize_state(state)

      return if run.phase == phase && run.phase_owner == owner && run.phase_summary == summary

      run.publish_phase!(phase: phase, owner: owner, summary: summary)
    end

    def infer_phase_owner(phase)
      case phase
      when "waiting_on_workers", "stalled"
        "worker"
      when "planning", "awaiting_user_feedback", "completed", "starting"
        "orchestrator"
      else
        "orchestrator"
      end
    end

    def summarize_state(state)
      return state[:last_stall_finding] if state[:last_stall_finding].present?
      return state[:last_plan_summary] if state[:last_plan_summary].present?

      case state[:phase]
      when "waiting_on_workers"
        "Waiting on active workers to report back."
      when "awaiting_user_feedback"
        "Awaiting user feedback before the next handoff can be planned."
      when "completed"
        "Run completed."
      else
        "Coordinating the next worker handoff."
      end
    end
  end
end
