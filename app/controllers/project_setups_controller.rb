class ProjectSetupsController < ApplicationController
  before_action :require_workspace

  def create
    run = current_workspace.runs.active.order(created_at: :desc).first
    if run
      Orchestrator::ProjectInitTrigger.call(run: run, force: true)
      redirect_back fallback_location: workspace_runs_path(current_workspace), notice: "Re-running project setup…"
    else
      Orchestrator::WorkspaceInit.launch!(current_workspace, force: true)
      redirect_to workspace_runs_path(current_workspace),
        notice: "Discovering dev environment and operational path metadata…"
    end
  end
end
