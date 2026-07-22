module Orchestrator
  # Launches the one bootstrap run that discovers a workspace's dev
  # environment and declares its protected paths (see ProjectInitTrigger and
  # McpTools::RecordProtectedPathsTool). Shared by WorkspacesController#create
  # (a brand-new workspace) and ProjectSetupsController#create (re-running
  # discovery for a workspace with no active run to piggyback on) so both
  # paths launch it identically.
  #
  # Deliberately does not go through LaunchRunJob: that job always seeds a
  # real "workflow-plan.md" planner SpawnRequest, which is right for a task
  # run but wrong here -- project_init's findings land as workspace-level
  # data (WorkspaceMemoryEntry, Workspace#protected_path_patterns), entirely
  # invisible to a planner's own acceptance-criteria bookkeeping. Queuing a
  # planner anyway was tried and confirmed to backfire: with no contract to
  # check against, it invented one and re-planned the same discovery as a
  # redundant "infrastructure" step. WorkerReconcileJob#complete_bootstrap_run!
  # is what actually ends this run once project_init succeeds.
  module WorkspaceInit
    module_function

    TASK = "Initialize workspace: discover the local dev environment and declare protected paths."

    def launch!(workspace, force: false)
      run = workspace.runs.create!(
        run_id: generate_run_id,
        task: TASK,
        target_root: workspace.root_path, launcher_variant: "claude",
        status: "launching", launched_by: "workspace_init"
      )
      Orchestrator::ProjectInitTrigger.call(run:, force:)
      run.update!(status: "running", started_at: Time.current)
      run
    end

    def generate_run_id
      "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
    end
    private_class_method :generate_run_id
  end
end
