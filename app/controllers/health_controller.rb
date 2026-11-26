class HealthController < ActionController::API
  def show
    response.set_header("X-Paneyard-Service", "paneyard")
    response.set_header("X-Paneyard-Role", PaneyardRole.current)
    render json: { status: "ok", service: "paneyard", role: PaneyardRole.current }
  end
end
