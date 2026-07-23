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
      return if run.publication_status.in?(%w[publishing published])

      if run.publication_status.in?(%w[committed no_changes])
        FinalizeRunPublicationJob.perform_later(run.id)
      else
        queue_committer(run)
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
      scope: "run-summary.md", execution_mode: "diagnosis", write_scope: "source_protected",
      text: "First call get_run_audit to inspect the committer-only persisted timeline, worker outcomes, and bounded worker reports; then use collect_workflow_state only to locate any final verifier artifacts needed to substantiate it. Write one concise, sanitized run-summary.md artifact for the PR reviewer with: outcome; source files changed; a chronological audit trail naming each material worker role/scope and outcome; failures or blocked attempts with their concrete boundary; recovery actions; verified acceptance evidence; unresolved limitations; and names of intentionally retained review artifacts. Do not run tests, linters, browser checks, or environment probes; the committer does not re-verify completed work. Distinguish confirmed verifier evidence from checks that were not run. Never include secrets, tokens, prompts, raw logs, environment snapshots, MCP configs, or command output. Then call commit_run_changes once. Rails stages source changes only and uses run-summary.md as the PR description; do not call worker_turn."
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
