# Replaces scripts/supervisor-loop.ts's tick loop -- instead of a
# dedicated, PID-tracked OS process per run, a recurring job (see
# config/recurring.yml) ticks every active run each time it fires: one
# orchestrator turn, then spawns whatever workers that turn's (or an
# earlier planner_turn's) spawn requests call for. Mirrors
# ReconcileRunsJob/WorkerReconcileJob's existing recurring-job pattern in
# this app.
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
    previous_state = Orchestrator::TickState.latest(run.run_id)
    return if previous_state[:phase] == "completed"

    result = Orchestrator::Turn.run_orchestrator_turn(
      run_id: run.run_id,
      task: run.task,
      previous_state: previous_state
    )
    Orchestrator::TickState.write(result[:next_state])
    Orchestrator::SpawnRequestedWorkers.call(run: run)

    # No separate OS process to wait for exiting anymore -- the job knows
    # synchronously the moment a tick reaches 'completed', so it flips the
    # run's own status right here instead of waiting on a later
    # reconciliation pass (see the now-removed ReconcileRunsJob, whose
    # entire purpose was detecting a dead supervisor_pid process).
    run.update!(status: "completed", stopped_at: Time.current) if result[:next_state][:phase] == "completed"
  end
end
