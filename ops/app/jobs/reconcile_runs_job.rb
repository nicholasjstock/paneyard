# Periodic liveness check for every non-terminal Run's supervisor_pid.
# Rails is the only place "which process drives run X" is tracked, so if
# that process dies outside Rails's awareness (OOM, host reboot, a manual
# `kill` outside the ops hub), the Run row would otherwise sit at
# status: "running" forever with no path back to reality. Cross-references
# Node's own /state so a run that actually finished gets marked
# "completed" rather than lumped in with a crash as "failed".
class ReconcileRunsJob < ApplicationJob
  queue_as :default

  def perform
    Run.where(status: %w[running stopping]).find_each do |run|
      next if run.supervisor_pid.blank?
      next if process_alive?(run.supervisor_pid)

      run.update!(status: reconciled_status(run), stopped_at: Time.current)
    end
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def reconciled_status(run)
    # workflow-bus.json's runStatuses are free-text summary events (only as
    # fresh as the last explicit publish_run_status call); the actual
    # source of truth for "did this run finish" is the orchestrator's own
    # decision-state phase enum, in its tick history's most recent entry.
    OrchestratorTick.for_run(run.run_id).last&.phase == "completed" ? "completed" : "failed"
  end
end
