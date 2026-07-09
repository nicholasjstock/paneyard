# Kills an entire run: cascades stop_worker to every still-running worker
# under it first (worker subprocesses are spawned detached: true on the
# Node side, so they do NOT die when the supervisor loop that spawned them
# is killed -- see scripts/workflow-worker-runtime.ts), then SIGTERMs the
# supervisor_launcher process itself, escalating to SIGKILL if it hasn't
# exited after a grace period.
class StopRunJob < ApplicationJob
  queue_as :default

  GRACE_PERIOD_SECONDS = 5

  def perform(id)
    run = Run.find(id)
    run.update!(status: "stopping")

    stop_active_workers(run)
    terminate_supervisor(run)

    run.update!(status: "stopped", stopped_at: Time.current)
  end

  private

  def stop_active_workers(run)
    Worker.where(run_id: run.run_id, status: "running").find_each do |worker|
      begin
        Process.kill("TERM", worker.pid) if process_alive?(worker.pid)
      rescue Errno::ESRCH
        nil
      end
      worker.update!(status: "stopped", stopped_at: Time.current, stop_reason: "run stopped from ops hub")
    rescue => e
      Rails.logger.warn("StopRunJob: failed to stop worker #{worker.worker_id} for run #{run.run_id}: #{e.message}")
    end
  end

  def terminate_supervisor(run)
    pid = run.supervisor_pid
    return if pid.blank? || !process_alive?(pid)

    Process.kill("TERM", pid)
    GRACE_PERIOD_SECONDS.times do
      sleep 1
      return unless process_alive?(pid)
    end
    Process.kill("KILL", pid) if process_alive?(pid)
  rescue Errno::ESRCH
    nil
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
