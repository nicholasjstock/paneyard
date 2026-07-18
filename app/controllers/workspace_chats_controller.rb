class WorkspaceChatsController < ApplicationController
  before_action :require_workspace

  def index
    chat = current_workspace.workspace_chats.first_or_create!
    redirect_to workspace_chat_path(current_workspace, chat)
  end

  def create
    chat = current_workspace.workspace_chats.first_or_create!
    redirect_to workspace_chat_path(current_workspace, chat)
  end

  def show
    @chat = current_workspace.workspace_chats.find(params[:id])
    @messages = @chat.messages.order(:created_at)
  end
end
