module Orchestrator
  # Workspace-scoped environment variables, discovered live by any worker
  # (e.g. a bundle install workaround) and merged into every future spawned
  # worker's and run command's process environment for this workspace.
  # Persists across runs, since a dev-environment quirk for a given project
  # is almost always still true in the next run.
  module WorkspaceEnvVars
    module_function

    def record!(run_id:, name:, value:, evidence_ref:, recorded_by:)
      run = Run.find_or_create_for_bus!(run_id)
      workspace = run.workspace

      entry = workspace.workspace_env_vars.find_or_initialize_by(name: name)
      entry.value = value
      entry.evidence_ref = evidence_ref
      entry.recorded_by = recorded_by
      entry.save!
      entry
    end

    # Merged as a base layer beneath WorkerSpawner's own identity/credential
    # env, and beneath a caller-supplied `environment:` on start_run_command
    # -- a recorded workaround should never be able to shadow a value the
    # orchestrator itself manages or a value the calling worker set explicitly
    # for this one invocation.
    def for_workspace(workspace)
      workspace.workspace_env_vars.pluck(:name, :value).to_h
    end
  end
end
