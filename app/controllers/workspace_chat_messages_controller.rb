class WorkspaceChatMessagesController < ApplicationController
  before_action :require_workspace

  def create
    chat = current_workspace.workspace_chats.find(params[:chat_id])
    if chat.status == "processing" || chat.messages.exists?(status: %w[queued processing])
      return redirect_to return_path(chat), alert: "Wait for the current chat turn to finish."
    end

    content = params.require(:workspace_chat_message).require(:content).to_s.strip
    message = chat.messages.create!(role: "user", content:, status: "queued")
    chat.update!(title: content.first(60)) if chat.messages.where(role: "user").count == 1
    WorkspaceChatTurnJob.perform_later(message.id)
    redirect_to return_path(chat)
  end

  private

  def return_path(chat)
    run = current_workspace.runs.find_by(run_id: params[:run_id])
    run ? workspace_run_path(current_workspace, run) : workspace_chat_path(current_workspace, chat)
  end
end
