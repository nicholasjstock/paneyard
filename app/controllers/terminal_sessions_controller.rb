class TerminalSessionsController < ApplicationController
  before_action :require_workspace

  def show
    @terminal_session = current_terminal_session
  end

  # The launcher/drawer is available from any workspace-scoped page (see
  # the layout), so restarting/stopping should return the operator to
  # whatever page they were on rather than always jumping to the
  # standalone terminal screen.
  def create
    session = current_terminal_session
    Orchestrator::TerminalSessionRunner.stop(session, reason: "Restarted by operator") if session.active?
    session.update!(cli_session_id: nil, launcher_variant: launcher_variant_param || session.launcher_variant, status: "starting")
    Orchestrator::TerminalSessionRunner.start(session)
    redirect_back fallback_location: workspace_terminal_session_path(current_workspace), notice: "Starting terminal session…"
  end

  def destroy
    session = current_terminal_session
    Orchestrator::TerminalSessionRunner.stop(session, reason: "Stopped by operator") if session.active?
    redirect_back fallback_location: workspace_terminal_session_path(current_workspace), notice: "Terminal session stopped."
  end

  private

  def launcher_variant_param
    params[:launcher_variant].presence_in(TerminalSession::LAUNCHER_VARIANTS)
  end
end
