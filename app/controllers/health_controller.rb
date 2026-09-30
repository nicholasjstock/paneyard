class HealthController < ActionController::API
  def show
    response.set_header("X-Paneyard-Service", "paneyard")
    render json: { status: "ok", service: "paneyard" }
  end
end
