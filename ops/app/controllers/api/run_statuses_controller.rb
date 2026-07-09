module Api
  class RunStatusesController < Api::BaseController
    # Replaces WorkflowBus#listRunStatuses -- the latest published phase
    # per run, across every run (used by supervisor-loop.ts's main() to
    # auto-resolve the most recently active run when no --run-id is given).
    def index
      runs = Run.where.not(phase: nil)
      render json: runs.map(&:phase_status_json)
    end

    def update
      run = Run.find_or_create_for_bus!(params[:runId])
      run.publish_phase!(phase: params[:phase], owner: params[:owner], summary: params[:summary])
      render json: run.phase_status_json
    end
  end
end
