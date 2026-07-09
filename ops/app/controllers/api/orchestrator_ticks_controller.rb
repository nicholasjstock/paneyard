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
      render json: Orchestrator::TickState.write(tick_params.to_h.symbolize_keys)
    end

    def latest
      render json: Orchestrator::TickState.latest(params[:runId])
    end

    def history
      render json: Orchestrator::TickState.history(params[:runId])
    end

    private

    def tick_params
      params.permit(
        :runId, :phase, :tickCount, :lastPlanSummary, :lastStallFinding,
        pendingSpawnKeys: [], followingSteps: [ :owner, :artifact, :successCheck ]
      )
    end
  end
end
