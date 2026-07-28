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
      # Each queue_finalization_worker call (seeder/reporter/curator/demo)
      # marks publication_status "commit_pending" as soon as it dispatches
      # that role -- not only once the whole chain reaches the git worker --
      # so this must always re-check the chain from the top rather than
      # branching on that status. Every call in the chain is itself cheap
      # and idempotent (a completed role's Worker row makes it return false
      # and fall through to the next), so re-evaluating it on every tick is
      # correct and costs nothing once the whole chain is done, at which
      # point RunPublication.queue_worker! itself no-ops behind its own
      # open-SpawnRequest guard.
      # The task text below is deliberately minimal -- agent_personas/<role>.md
      # is auto-prepended to every spawn of that role (WorkerSpawner#build_prompt_with_persona)
      # and already states the complete behavior; repeating it here used to
      # duplicate that file by hand, with no mechanism keeping the two in sync.
      queue_finalization_worker(run, "seeder", "seed-data.md", "Begin.", write_scope: "scoped_changes", execution_mode: "implementation") ||
        queue_finalization_worker(run, "reporter", "run-summary.md", "Begin.") ||
        queue_finalization_worker(run, "curator", "review-assets.md", "Begin.") ||
        queue_finalization_worker(run, "demo", "demo-notes.md", "Begin.") ||
        Orchestrator::RunPublication.queue_worker!(run)
      Orchestrator::SpawnRequestedWorkers.call(run: run)
    else
      run.update!(status: "completed", stopped_at: run.stopped_at || Time.current) unless run.status == "completed"
    end
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

  def queue_finalization_worker(run, role, scope, text, write_scope: "source_protected", execution_mode: "diagnosis")
    return true if Worker.active.exists?(run_id: run.run_id, role: role) || SpawnRequest.where(run_id: run.run_id, requested_role: role, status: "open").exists?
    return false if Worker.where(run_id: run.run_id, role: role).where.not(handoff_completed_at: nil).exists?

    run.update!(publication_status: "commit_pending", publication_error: nil)
    SpawnRequest.create!(run_id: run.run_id, asked_by: "orchestrator", requested_role: role, priority: "blocking", scope:, execution_mode:, write_scope:, text:)
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
