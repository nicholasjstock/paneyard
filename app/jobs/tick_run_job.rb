# The scheduler is an executor and liveness observer, not a second planner.
# PlannerTurnTool is the sole writer of a run's decision state. This job
# fulfills requests that decision has already published and, after a real
# lifecycle failure, requests a recovery planner without overwriting the
# planner's state.
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
    request_recovery_planner_if_dead_end(run, previous_state)
  end

  def request_recovery_planner_if_dead_end(run, previous_state)
    return if Worker.where(run_id: run.run_id, status: "running").exists?
    return if SpawnRequest.where(run_id: run.run_id, status: "open").exists?
    return if previous_state[:phase].in?(%w[starting completed blocked_on_user])

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
