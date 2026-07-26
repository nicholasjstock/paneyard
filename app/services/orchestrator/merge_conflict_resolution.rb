module Orchestrator
  module MergeConflictResolution
    module_function

    SCOPE = "merge-conflict-resolution.md"

    def queue_worker!(run)
      return if Worker.active.where(run_id: run.run_id, role: "worker").exists?
      return if SpawnRequest.where(run_id: run.run_id, scope: SCOPE, status: "open").exists?

      paths = RunPublication.merge_conflict_paths(run)
      raise RunPublication::Error, "Git reported a rebase conflict but named no source paths" if paths.empty?

      run.update!(status: "running", publication_status: "merge_conflict")
      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "orchestrator", requested_role: "worker", priority: "blocking",
        scope: SCOPE, execution_mode: "implementation", write_scope: "scoped_changes", allowed_paths: paths,
        text: "Resolve the current rebase conflicts in the exact authorized files. Preserve both intended behaviors, remove all conflict markers, and report what you resolved. Do not run git: Rails owns the active rebase and will continue it after your handoff.",
        context: "Git rebase onto origin/main conflicted in: #{paths.join(', ')}", tags: %w[git merge-conflict resolution]
      )
      run.publish_phase!(phase: "resolving_merge_conflict", owner: "orchestrator", summary: "A source worker is resolving conflicts with the latest main.")
    end

    def continue_if_ready!(run)
      return if Worker.active.where(run_id: run.run_id).exists?
      return if SpawnRequest.where(run_id: run.run_id, scope: SCOPE, status: "open").exists?

      request = SpawnRequest.where(run_id: run.run_id, scope: SCOPE).order(created_at: :desc).first
      return queue_worker!(run) unless request&.status == "fulfilled"
      worker = Worker.find_by(worker_id: request.fulfilled_worker_id)
      return queue_worker!(run) unless worker&.handoff_completed_at

      result = RunPublication.continue_rebase_onto_main!(run, paths: request.allowed_paths)
      if result == :conflicted
        queue_worker!(run)
      else
        run.update!(publication_status: "committed", publication_error: nil)
        FinalizeRunPublicationJob.perform_later(run.id)
      end
    rescue RunPublication::Error => error
      run.update!(status: "failed", publication_status: "failed", publication_error: error.message)
      run.publish_phase!(phase: "failed", owner: "orchestrator", summary: "Merge-conflict resolution failed: #{error.message}")
    end
  end
end
