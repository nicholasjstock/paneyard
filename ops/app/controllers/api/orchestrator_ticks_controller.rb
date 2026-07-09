module Api
  class OrchestratorTicksController < Api::BaseController
    # Upsert by (run_id, tick_count), not a strict create: the TS callers
    # this replaces always call writeOrchestratorState *and*
    # appendOrchestratorTickHistory back-to-back with the same state (two
    # separate operations against the old JSON files -- "overwrite the
    # current snapshot" and "append to history" -- that both map onto this
    # one immutable-row-per-tick table here). A strict create! would raise
    # on the second call's now-duplicate (run_id, tick_count) pair.
    def create
      run = Run.find_or_create_for_bus!(tick_params[:runId])
      tick = OrchestratorTick.find_or_initialize_by(run_id: run.run_id, tick_count: tick_params[:tickCount])
      tick.assign_attributes(
        phase: tick_params[:phase],
        last_plan_summary: tick_params[:lastPlanSummary],
        pending_spawn_keys: tick_params[:pendingSpawnKeys] || [],
        following_steps: (tick_params[:followingSteps] || []).map(&:to_h),
        last_stall_finding: tick_params[:lastStallFinding]
      )
      tick.save!
      render json: tick
    end

    def latest
      tick = OrchestratorTick.for_run(params[:runId]).last
      render json: tick || default_state(params[:runId])
    end

    def history
      ticks = OrchestratorTick.for_run(params[:runId])
      render json: { runId: params[:runId], entries: ticks.map(&:as_json) }
    end

    private

    def tick_params
      params.permit(
        :runId, :phase, :tickCount, :lastPlanSummary, :lastStallFinding,
        pendingSpawnKeys: [], followingSteps: [ :owner, :artifact, :successCheck ]
      )
    end

    def default_state(run_id)
      {
        runId: run_id, phase: "starting", tickCount: 0, lastPlanSummary: nil,
        pendingSpawnKeys: [], followingSteps: [], lastStallFinding: nil, lastUpdatedAt: nil
      }
    end
  end
end
