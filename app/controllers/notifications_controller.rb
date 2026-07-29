class NotificationsController < ApplicationController
  before_action :require_workspace

  def index
    @notifications = Notification.recent_first
  end

  def mark_read
    notification = Notification.find(params[:id])
    notification.mark_read!

    redirect_to notifications_redirect_path(notification), notice: "Notification marked as read."
  end

  private

  def notifications_redirect_path(notification)
    return notification.target_url if notification.target_url.present?

    workspace_notifications_path(current_workspace)
  end
end
