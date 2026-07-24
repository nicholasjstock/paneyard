# Periodic liveness check for every TerminalSession row still marked
# active. Mirrors WorkerReconcileJob's redundant-safety-net role: a session
# whose pty child died without this process's reader thread noticing (e.g.
# a Rails restart severed it) gets marked exited here instead of sitting
# "running" forever.
class TerminalSessionReconcileJob < ApplicationJob
  queue_as :default

  def perform
    TerminalSession.active.find_each { |session| Orchestrator::TerminalSessionRunner.reconcile!(session) }
  end
end
