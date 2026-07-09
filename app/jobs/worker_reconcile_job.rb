# Periodic liveness check for every Worker row still marked "running".
# A worker's spawning process (TickRunJob, or that worker's own MCP
# client, depending on which path recorded it) might not notice its
# exit -- Rails can independently confirm liveness the same way
# StopRunJob/Orchestrator::WorkerSpawner already do (Process.kill(0, pid)
# works fine for a process this Rails instance didn't fork, same host).
#
# This is a redundant safety net, not the primary detection path. Losing
# exact exit-code fidelity for a Rails-detected-only stop is an
# acceptable, already-anticipated degradation -- Worker#stop_reason
# already treats this as best-effort.
class WorkerReconcileJob < ApplicationJob
  queue_as :default

  def perform
    Worker.active.find_each do |worker|
      next if process_alive?(worker.pid)

      worker.update!(
        status: "stopped",
        stopped_at: Time.current,
        stop_reason: worker.stop_reason.presence || "Process no longer running (detected by Rails reconciliation, not the original parent process)."
      )
    end
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
