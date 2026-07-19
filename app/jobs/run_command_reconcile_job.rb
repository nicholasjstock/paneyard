# Periodic safety net mirroring WorkerReconcileJob: reconciles every
# RunCommand still marked "running" against actual OS state (a command's
# spawning worker or even the Rails process itself may have restarted since
# it was started -- see Orchestrator::RunCommandRunner), and sweeps commands
# stuck in "pending" (the post-spawn status update never landed).
class RunCommandReconcileJob < ApplicationJob
  queue_as :default

  def perform
    Orchestrator::RunCommandRunner.reconcile_active!
  end
end
