class RunCommandsController < ApplicationController
  before_action :require_workspace

  def stop
    command = workspace_run_commands.find_by!(command_id: params[:command_id])
    Orchestrator::RunCommandRunner.stop(command: command, reason: stop_reason)
    redirect_back fallback_location: workspace_runs_path(current_workspace), notice: "Run command stopped."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: workspace_runs_path(current_workspace), alert: "Failed to stop run command: unknown command #{params[:command_id]}"
  end

  private

  def workspace_run_commands
    RunCommand.joins(:run).where(runs: { workspace_id: current_workspace.id })
  end

  def stop_reason
    params[:reason].presence || "manually stopped from ops hub"
  end
end
