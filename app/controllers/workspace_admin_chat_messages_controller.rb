class WorkspaceAdminChatMessagesController < ApplicationController
  before_action :require_workspace

  def create
    chat = current_workspace_admin_chat
    content = params.require(:workspace_admin_chat_message).fetch(:content, "").to_s.strip
    if content.blank?
      return redirect_back fallback_location: workspace_runs_path(current_workspace), alert: "Message can't be blank."
    end

    Orchestrator::WorkspaceAdminChatDriver::Runner.start_turn!(chat:, content:)
    redirect_back fallback_location: workspace_runs_path(current_workspace)
  rescue Orchestrator::WorkspaceAdminChatDriver::Runner::ConcurrentTurnError
    redirect_back fallback_location: workspace_runs_path(current_workspace), alert: "Wait for the current turn to finish."
  end
end
