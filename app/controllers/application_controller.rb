class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern unless Rails.env.test?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_workspace
  helper_method :current_terminal_session
  helper_method :current_workspace_admin_chat
  helper_method :current_runs
  helper_method :background_job_warning
  helper_method :current_notifications
  helper_method :unread_notification_count

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

  # Every workspace has exactly one terminal session slot -- available from
  # any workspace-scoped page (see the layout's launcher/drawer), not just
  # the run screen it originally lived on.
  def current_terminal_session
    return unless current_workspace

    @current_terminal_session ||= current_workspace.terminal_session ||
      current_workspace.create_terminal_session!
  end

  # Every workspace has exactly one admin-chat slot, same one-per-workspace
  # shape as current_terminal_session -- available from any workspace-scoped
  # page once the layout links to it.
  def current_workspace_admin_chat
    return unless current_workspace

    @current_workspace_admin_chat ||= current_workspace.workspace_admin_chat ||
      current_workspace.create_workspace_admin_chat!
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

  def current_notifications
    @current_notifications ||= Notification.recent_first.limit(5)
  end

  def unread_notification_count
    @unread_notification_count ||= Notification.unread.count
  end
end
