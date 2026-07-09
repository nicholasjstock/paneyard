# Stops an entire run: cascades stop to every still-running worker under
# it (real Process.kill, same host), then flips the run's own status to
# 'stopping'/'stopped' -- TickRunJob only ever ticks status: "running"
# runs, so it naturally stops picking this run up on its next firing.
# There's no supervisor_launcher OS process to separately terminate
# anymore (contrast with the old grace-period TERM-then-KILL escalation
# this replaced -- that existed only because the old tick loop was a
# separate long-lived process; a recurring job has nothing to kill).
class StopRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    run.update!(status: "stopping")

    stop_active_workers(run)

    run.update!(status: "stopped", stopped_at: Time.current)
  end

  private

  def stop_active_workers(run)
    Worker.where(run_id: run.run_id, status: "running").find_each do |worker|
      Orchestrator::WorkerSpawner.stop_worker(worker: worker, reason: "run stopped from ops hub")
    rescue => e
      Rails.logger.warn("StopRunJob: failed to stop worker #{worker.worker_id} for run #{run.run_id}: #{e.message}")
    end
  end
end
