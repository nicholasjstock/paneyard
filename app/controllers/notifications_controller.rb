class NotificationsController < ApplicationController
  before_action :set_workspace, if: -> { params[:workspace_id].present? }

  def index
    @notifications = Notification.recent_first
  end

  def mark_read
    notification = Notification.find(params[:id])
    notification.mark_read!

    redirect_to notifications_redirect_path(notification), notice: "Notification marked as read."
  end

  def mark_all_read
    Notification.unread.update_all(read_at: Time.current)

    head :no_content
  end

  def open
    notification = Notification.find(params[:id])
    notification.mark_read!

    if notification.target_url.present?
      redirect_to notification.target_url, allow_other_host: true
    else
      redirect_to workspace_questions_path(notification.workspace)
    end
  end

  private

  def notifications_redirect_path(notification)
    return notification.target_url if notification.target_url.present?

    current_workspace ? workspace_notifications_path(current_workspace) : notifications_path
  end

  def set_workspace
    @current_workspace = Workspace.find(params[:workspace_id])
  end
end
