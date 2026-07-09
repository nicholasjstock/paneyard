# Periodic liveness check for every Worker row still marked "running".
# Mirrors ReconcileRunsJob's reasoning but for individual worker
# subprocesses: the supervisor loop that spawned a worker (or that
# worker's own MCP client, depending on which path recorded it) might
# itself have died without ever reporting the worker's exit -- Rails can
# independently confirm liveness the same way StopRunJob already does
# (Process.kill(0, pid) works fine for a process this Rails instance
# didn't fork, same host).
#
# This is a redundant safety net, not the primary detection path: Node's
# own workerRuntime.listWorkers()/refreshWorkers() has better fidelity
# (real exit code/signal, since it's the actual parent process) and PATCHes
# Rails when it detects a stop on its own. Losing exact exit-code fidelity
# for a Rails-detected-only stop is an acceptable, already-anticipated
# degradation -- Worker#stop_reason already treats this as best-effort.
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
