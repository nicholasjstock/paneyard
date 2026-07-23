class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern unless Rails.env.test?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_workspace
  helper_method :current_runs
  helper_method :background_job_warning

  private

  # No auth in v1 (single-user local tool) -- placeholder for whoever is
  # at the keyboard, kept as a distinct concept so it's easy to wire up
  # real auth later without touching the rest of the launch/answer flows.
  def current_operator
    "operator"
  end

  def current_workspace
    @current_workspace
  end

  def current_runs
    @current_runs ||= Run.active.includes(:workspace).order(created_at: :desc)
  end

  def require_workspace
    @current_workspace = Workspace.find(params[:workspace_id])
  end

  def background_job_warning
    @background_job_warning ||= BackgroundJobHealth.warning
  end
end
