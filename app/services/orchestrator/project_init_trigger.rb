module Orchestrator
  # Seeds the one-shot, workspace-scoped project-setup discovery request.
  # The gate is existing data, not a separate flag: as long as the primary
  # entry_key already exists in this workspace's durable memory, calling
  # this again is a no-op -- see WorkerReconcileJob#handle_project_init_worker_stop
  # for the matching completion/idempotency check on the other end.
  module ProjectInitTrigger
    module_function

    PRIMARY_ENTRY_KEY = "dev-environment"

    PROMPT = <<~TEXT.squish
      Explore this repository (read-only) and determine exactly how to start its full local development
      environment. Prefer a single unified command if the project has one (for example a script that starts every
      needed service together). If no single command exists, identify the exact separate commands required and
      state that clearly instead of leaving it to be guessed later. Call record_project_setup with your findings
      before finishing; your primary finding must use key "#{PRIMARY_ENTRY_KEY}". You may add up to 4 more findings
      for other clearly load-bearing commands (running tests, building for production) only if you find them with
      the same evidence standard. Also call record_protected_paths exactly once with only genuinely high-impact
      operational files you find (credentials, production environment configuration, or deployment configuration).
      Do not include ordinary application source, views, controllers, routes, tests, schemas, or migrations: workers
      receive exact per-step allowed paths for normal implementation work. This call is required, not optional: no
      real task run can start on this workspace until it lands. Do not modify any files.
    TEXT

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
