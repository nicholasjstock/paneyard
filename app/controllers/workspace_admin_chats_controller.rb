class WorkspaceAdminChatsController < ApplicationController
  before_action :require_workspace

  # No standalone show page -- the drawer (see shared/_admin_chat_launcher)
  # is the only surface, available from any workspace page, so every action
  # here returns to wherever the operator actually was (falling back to the
  # main workspace window if there's no referer to return to).
  def update
    chat = current_workspace_admin_chat
    provider = params[:active_provider].presence_in(WorkspaceAdminChat::PROVIDERS)
    chat.update!(active_provider: provider) if provider

    claude_model = params[:claude_model].presence_in(WorkspaceAdminChat::CLAUDE_MODELS)
    chat.update!(claude_model:) if claude_model
    codex_model = params[:codex_model].presence_in(WorkspaceAdminChat::CODEX_MODELS)
    chat.update!(codex_model:) if codex_model

    redirect_back fallback_location: workspace_runs_path(current_workspace)
  end

  def cancel
    Orchestrator::WorkspaceAdminChatDriver::Runner.cancel_turn!(current_workspace_admin_chat)
    redirect_back fallback_location: workspace_runs_path(current_workspace)
  end

  def reset
    chat = current_workspace_admin_chat
    provider = params[:provider].presence_in(WorkspaceAdminChat::PROVIDERS) || chat.active_provider
    if chat.active? && chat.active_provider == provider
      return redirect_back fallback_location: workspace_runs_path(current_workspace),
        alert: "Cancel the running turn before resetting this conversation."
    end

    chat.reset_session!(provider)
    redirect_back fallback_location: workspace_runs_path(current_workspace), notice: "#{provider.capitalize} conversation reset."
  end
end
