# Machine-to-machine JSON API for the Node-side HTTP-backed bus client --
# no session/cookies/CSRF, matching the same trust model as the
# internal-only shim it replaces (scripts/workflow-mcp-http.ts's
# /internal/tools/:name), which relied on localhost-binding rather than
# app-level auth.
module Api
  class BaseController < ActionController::API
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::RecordInvalid, with: :render_invalid

    private

    def render_not_found(error)
      render json: { error: error.message }, status: :not_found
    end

    def render_invalid(error)
      render json: { error: error.message, details: error.record.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
