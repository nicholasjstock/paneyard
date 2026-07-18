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
      run.update!(status: "completed", stopped_at: run.stopped_at || Time.current) unless run.status == "completed"
      return
    end

    Orchestrator::SpawnRequestedWorkers.call(run: run)
    clear_expired_capacity_phase(run)
    request_recovery_planner_if_dead_end(run, previous_state)
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
    return if previous_state[:phase] == "blocked_on_user" && UserQuestion.exists?(run_id: run.run_id, status: "open", priority: "blocking")

    finding = Orchestrator::Turn.build_dead_end_finding(
      run_id: run.run_id,
      following_steps: previous_state[:following_steps] || []
    )
    plan = Orchestrator::Planner.build_stalled_worker_recovery_plan(
      task: run.task,
      recovery_finding: finding,
      following_steps: previous_state[:following_steps] || []
    )
    Orchestrator::Planner.publish_planner_jobs(run_id: run.run_id, summary: plan[:summary], plan: plan)
  end
end
