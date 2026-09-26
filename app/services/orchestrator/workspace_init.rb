module Orchestrator
  # Queues the one bootstrap run that discovers a workspace's dev environment
  # and declares its protected paths. Shared by WorkspacesController#create (a
  # brand-new workspace) and ProjectSetupsController#create (re-running
  # discovery).
  #
  # This used to need its own dispatch path, because the normal one always
  # seeded a planner decision and a planner given a discovery task with no
  # contract to check against would invent one and re-plan the discovery as a
  # redundant implementation step. With the planner gone there is nothing to
  # special-case: a bootstrap run is an ordinary queued run whose task happens
  # to be "look, don't change".
  module WorkspaceInit
    module_function

    PRIMARY_ENTRY_KEY = "dev-environment"

    TASK = <<~TASK.strip
      Initialize this workspace. Do not change any code -- this run is discovery only, and should end with
      nothing to commit.

      1. Work out how to run this project's local development environment end to end: dependency install,
         database setup, how to start it, and how to run its tests. Verify what you can by actually running it.
      2. Record what you learned with `record_project_setup`, including one finding keyed
         "#{PRIMARY_ENTRY_KEY}" that states exactly how to start the full dev environment.
      3. Declare this workspace's protected source paths with `record_protected_paths` -- source,
         configuration, and maintained tests, but not dependency caches, build output, or generated files.
      4. Call `report_idle` with outcome `done`.
    TASK

    def launch!(workspace, force: false)
      if !force && workspace.workspace_memory_entries.current.exists?(entry_key: PRIMARY_ENTRY_KEY)
        return nil
      end

      workspace.runs.create!(
        run_id: generate_run_id,
        task: TASK,
        target_root: workspace.source_root,
        launcher_variant: "claude",
        status: "queued",
        launched_by: "workspace_init"
      ).tap do |run|
        run.worktree_name = GitWorktree.name_for(run)
        run.save!
        RunDispatchJob.perform_later
      end
    end

    def generate_run_id
      "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
    end
    private_class_method :generate_run_id
  end
end
