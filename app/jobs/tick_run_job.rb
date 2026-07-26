# The scheduler is an executor and liveness observer, not a second planner.
# Rails owns orchestration state and process dispatch. This job fulfills
# worker requests directly, queues bounded PlannerDecisionJob calls for
# planning requests, and requests recovery planning after a real lifecycle
# failure without asking a model to coordinate process state.
class TickRunJob < ApplicationJob
  queue_as :default

  def perform
    Run.where(status: "running").find_each do |run|
      tick_run(run)
    rescue => e
      Rails.logger.error("TickRunJob: failed to tick run #{run.run_id}: #{e.class}: #{e.message}")
    end
  end

  private

  def tick_run(run)
    if run.publication_status == "merge_conflict"
      Orchestrator::MergeConflictResolution.continue_if_ready!(run)
      return
    end

    if run.capacity_blocked?
      run.publish_phase!(
        phase: "waiting_on_capacity",
        owner: "orchestrator",
        summary: "Claude capacity is unavailable; retrying after #{run.capacity_available_at.in_time_zone.strftime('%H:%M %Z')}."
      )
      return
    end

    previous_state = Orchestrator::TickState.latest(run.run_id)
    if previous_state[:phase] == "completed"
      finalize_completed_run(run)
      return
    end

    Orchestrator::SpawnRequestedWorkers.call(run: run)
    clear_expired_capacity_phase(run)
    request_recovery_planner_if_dead_end(run, previous_state)
  end

  def finalize_completed_run(run)
    if run.worktree_name.present?
      return if run.publication_status.in?(%w[publishing published])

      if run.publication_status.in?(%w[committed no_changes])
        FinalizeRunPublicationJob.perform_later(run.id)
      else
        queue_finalization_worker(run, "reporter", "run-summary.md", "Audit the persisted run with get_run_audit and write the reviewer-facing PR audit to run-summary.md. Do not run tests, select files, commit, or publish.") ||
          queue_finalization_worker(run, "curator", "review-assets.md", "Inspect real local deliverables only. Select useful reviewer files with select_review_assets, or write that no review assets were selected. Do not audit the run, run tests, commit, or publish.") ||
          queue_committer(run)
        Orchestrator::SpawnRequestedWorkers.call(run: run)
      end
    else
      run.update!(status: "completed", stopped_at: run.stopped_at || Time.current) unless run.status == "completed"
    end
  end

  def queue_committer(run)
    return if Worker.active.exists?(run_id: run.run_id, role: "committer")
    return if SpawnRequest.where(run_id: run.run_id, requested_role: "committer", status: "open").exists?

    run.update!(publication_status: "commit_pending", publication_error: nil)
    SpawnRequest.create!(
      run_id: run.run_id, asked_by: "orchestrator", requested_role: "committer", priority: "blocking",
      scope: "commit-#{run.worktree_name}.md", execution_mode: "diagnosis", write_scope: "source_protected",
      text: "Inspect git status, call list_git_change_requests and reconcile what workers asked to exclude, then call " \
        "commit_run_changes exactly once with excludePaths set to whichever of those you decide to honor. Do not " \
        "write a run summary, select review assets, run tests, inspect run audits, publish, or call worker_turn."
    )
    run.publish_phase!(phase: "committing", owner: "orchestrator", summary: "A committer is reviewing and committing the complete run worktree.")
  end

  def clear_expired_capacity_phase(run)
    return unless run.phase == "waiting_on_capacity"

    active_worker = Worker.where(run_id: run.run_id, status: "running").order(started_at: :desc).first
    if active_worker
      run.publish_phase!(
        phase: "waiting_on_workers",
        owner: active_worker.role,
        summary: "#{active_worker.nickname} is active on #{active_worker.scope}."
      )
    elsif SpawnRequest.where(run_id: run.run_id, status: "open").exists?
      run.publish_phase!(
        phase: "planning",
        owner: "orchestrator",
        summary: "Capacity is available; the next handoff is queued."
      )
    else
      run.publish_phase!(
        phase: "planning",
        owner: "orchestrator",
        summary: "Capacity is available; evaluating the next handoff."
      )
    end
  end

  def queue_finalization_worker(run, role, scope, text)
    return true if Worker.active.exists?(run_id: run.run_id, role: role) || SpawnRequest.where(run_id: run.run_id, requested_role: role, status: "open").exists?
    return false if Worker.where(run_id: run.run_id, role: role).where.not(handoff_completed_at: nil).exists?

    run.update!(publication_status: "commit_pending", publication_error: nil)
    SpawnRequest.create!(run_id: run.run_id, asked_by: "orchestrator", requested_role: role, priority: "blocking", scope:, execution_mode: "diagnosis", write_scope: "source_protected", text:)
    run.publish_phase!(phase: "committing", owner: "orchestrator", summary: "#{role.humanize} is finalizing the run.")
    true
  end

  def request_recovery_planner_if_dead_end(run, previous_state)
    return if Worker.where(run_id: run.run_id, status: "running").exists?
    return if PlannerDecision.active.where(run_id: run.run_id).exists?
    return if SpawnRequest.where(run_id: run.run_id, status: "open").exists?
    return if previous_state[:phase].in?(%w[starting completed])
    # Checked independent of previous_state[:phase]: that mirror is only
    # refreshed by an actual worker/planner Turn, so a blocking question
    # raised outside a Turn (e.g. a chaperone review that failed instead of
    # reaching a decision) would otherwise leave this stale and let recovery
    # dispatch new work behind a question the operator hasn't answered yet.
    return if UserQuestion.exists?(run_id: run.run_id, status: "open", priority: "blocking")
    # A criterion stuck awaiting verification with nothing in flight is
    # re-armed with a fresh verifier request rather than handed to a
    # recovery planner, which cannot legally dispatch verifier-role work
    # (StepPolicy::PLANNER_STEP_OWNERS). Covers verifier deaths that never
    # record a StepAttempt, e.g. one killed by a capacity limit.
    return if Orchestrator::VerifierRecovery.requeue_stalled_verification!(run)

    finding = Orchestrator::Turn.build_dead_end_finding(
      run_id: run.run_id,
      following_steps: previous_state[:following_steps] || []
    )
    finding = [ finding, recovery_artifact_evidence(run) ].compact.join(" ")
    plan = Orchestrator::Planner.build_stalled_worker_recovery_plan(
      task: run.task,
      recovery_finding: finding,
      following_steps: previous_state[:following_steps] || []
    )
    Orchestrator::Planner.publish_planner_jobs(run_id: run.run_id, summary: plan[:summary], plan: plan)
  end

  def recovery_artifact_evidence(run)
    worker = run.workers.where(status: "stopped").order(stopped_at: :desc).first
    return unless worker

    window = Orchestrator::ArtifactStore.read_window(run.target_root, run.run_id, worker.scope, offset: 0, limit: 6_000)
    "Recovery artifact #{worker.scope} from #{worker.nickname}:\n#{window[:content]}"
  rescue Errno::ENOENT, ArgumentError
    nil
  end
end
