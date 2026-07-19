class HealthController < ActionController::API
  def show
    response.set_header("X-Workflow-Service", "workflow-orchestrator")
    render json: { status: "ok", service: "workflow-orchestrator" }
  end
end
