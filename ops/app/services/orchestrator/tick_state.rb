module Orchestrator
  # Shared read/write for OrchestratorTick, used by both Api::OrchestratorTicksController
  # and the McpTools orchestrator-state tools -- one row per tick serves as
  # both "current state" and "history entry" (see OrchestratorTick's own
  # comment), replacing the old TS Rails-HTTP-client's separate
  # writeOrchestratorState/appendOrchestratorTickHistory calls with a single
  # upsert.
  module TickState
    module_function

    def write(state)
      state = deep_symbolize(state)
      run = Run.find_or_create_for_bus!(state[:runId])
      tick = OrchestratorTick.find_or_initialize_by(run_id: run.run_id, tick_count: state[:tickCount])
      tick.assign_attributes(
        phase: state[:phase],
        last_plan_summary: state[:lastPlanSummary],
        pending_spawn_keys: state[:pendingSpawnKeys] || [],
        following_steps: state[:followingSteps] || [],
        last_stall_finding: state[:lastStallFinding]
      )
      tick.save!
      deep_symbolize(tick.as_json)
    end

    def latest(run_id)
      tick = OrchestratorTick.for_run(run_id).last
      tick ? deep_symbolize(tick.as_json) : default_state(run_id)
    end

    def history(run_id)
      { runId: run_id, entries: OrchestratorTick.for_run(run_id).map { |tick| deep_symbolize(tick.as_json) } }
    end

    def default_state(run_id)
      {
        runId: run_id,
        phase: "starting",
        tickCount: 0,
        lastPlanSummary: nil,
        pendingSpawnKeys: [],
        followingSteps: [],
        lastStallFinding: nil,
        lastUpdatedAt: nil
      }
    end

    # OrchestratorTick#following_steps round-trips through a JSON column as
    # string-keyed hashes, while every state/step hash built fresh in
    # Orchestrator::Planner/Turn uses symbol keys -- deep-symbolizing at
    # this boundary means callers never have to care which one they're
    # holding.
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
  end
end
