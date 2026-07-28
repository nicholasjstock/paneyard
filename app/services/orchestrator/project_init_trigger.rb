module Orchestrator
  # Seeds the one-shot, workspace-scoped project-setup discovery request.
  # The gate is existing data, not a separate flag: as long as the primary
  # entry_key already exists in this workspace's durable memory, calling
  # this again is a no-op -- see WorkerReconcileJob#handle_project_init_worker_stop
  # for the matching completion/idempotency check on the other end.
  module ProjectInitTrigger
    module_function

    PRIMARY_ENTRY_KEY = "dev-environment"

    # "Begin." is deliberate -- agent_personas/project_init.md is
    # auto-prepended to every project_init spawn and already states this
    # role's complete behavior (including the "dev-environment" key by name)
    # in more detail than fit here; this used to restate a condensed version
    # of it by hand, with nothing keeping the two in sync.
    PROMPT = "Begin."

    def call(run:, force: false)
      workspace = run.workspace
      return if !force && workspace.workspace_memory_entries.current.exists?(entry_key: PRIMARY_ENTRY_KEY)
      return if SpawnRequest.where(run_id: run.run_id, requested_role: "project_init", status: "open").exists?

      run.spawn_requests.create!(
        asked_by: "orchestrator", scope: "project-setup", text: PROMPT,
        requested_role: "project_init", priority: "blocking", execution_mode: "diagnosis",
        write_scope: "source_protected", lineage_key: "project-init:#{workspace.id}", tags: %w[project-init]
      )
    end
  end
end
