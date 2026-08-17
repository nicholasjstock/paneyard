class ProjectSetupsController < ApplicationController
  before_action :require_workspace

  # Re-runs a workspace's bootstrap discovery. It is an ordinary run now, so
  # there is nothing to piggyback on an in-flight one: it queues like any
  # other and waits its turn.
  def create
    Orchestrator::WorkspaceInit.launch!(current_workspace, force: true)
    redirect_to workspace_runs_path(current_workspace),
      notice: "Queued a run to rediscover this workspace's dev environment and protected paths…"
  end
end
