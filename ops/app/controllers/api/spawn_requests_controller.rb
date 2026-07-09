module Api
  class SpawnRequestsController < Api::BaseController
    def index
      scope = SpawnRequest.all
      scope = scope.where(run_id: params[:runId]) if params[:runId].present?
      scope = scope.open_only if params[:status] == "open"
      render json: scope.map(&:as_json)
    end

    def create
      run = Run.find_or_create_for_bus!(spawn_request_params[:runId])
      spawn_request = SpawnRequest.create!(
        run_id: run.run_id,
        asked_by: spawn_request_params[:askedBy],
        scope: spawn_request_params[:scope],
        text: spawn_request_params[:text],
        context: spawn_request_params[:context],
        requested_role: spawn_request_params[:requestedRole],
        priority: spawn_request_params[:priority].presence || "advisory",
        tags: spawn_request_params[:tags] || []
      )
      render json: spawn_request
    end

    def fulfill
      spawn_request = SpawnRequest.find_by!(request_id: params[:id])
      spawn_request.update!(
        status: "fulfilled",
        fulfilled_by: params[:fulfilledBy],
        fulfilled_at: Time.current,
        fulfillment_note: params[:fulfillmentNote],
        fulfilled_worker_id: params[:fulfilledWorkerId]
      )
      render json: spawn_request
    end

    def dismiss
      spawn_request = SpawnRequest.find_by!(request_id: params[:id])
      spawn_request.update!(
        status: "dismissed",
        dismissed_by: params[:dismissedBy],
        dismissed_at: Time.current,
        dismissal_note: params[:dismissalNote]
      )
      render json: spawn_request
    end

    private

    def spawn_request_params
      params.permit(:runId, :askedBy, :scope, :text, :context, :requestedRole, :priority, tags: [])
    end
  end
end
