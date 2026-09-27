# The safety net for sessions that die without anyone noticing.
#
# A session is not supposed to end on its own: it reports going idle via
# report_idle and then waits, pane open, for the operator to decide what
# happens next. This job covers the ways that waiting can stop being real --
# the operator closed the pane by hand, the CLI crashed or was quit, herdr
# restarted. Without it those runs would hold their concurrency slot forever,
# since Rails learns nothing from a pane that simply stops existing.
#
# An idle session is emphatically NOT an anomaly here. It is live, its process
# is up, and it is waiting on the operator, so this job leaves it alone; only
# refresh! deciding the pane or process is gone ends anything.
#
# It also refreshes what herdr knows about each live session -- the agent
# status the run screen renders, and the CLI's own session id, which is the
# only way to obtain a --resume id for an interactive session.
#
# Closing a run's herdr workspace by hand (agent pane and editor pane together)
# is also how the operator says they are done with its worktree, without ever
# opening the run screen. So a session this job finds ended gets the same
# WorktreeJanitor.release! that Close session gives it: the worktree goes only
# when its work is committed and pushed or merged, and is otherwise kept,
# exactly as Close session would keep it.
class RunSessionReconcileJob < ApplicationJob
  queue_as :default

  def perform
    RunSession.live.includes(:run).find_each do |session|
      Orchestrator::RunSessionRunner.refresh!(session)

      # Only a session that refresh! just ended needs finishing off -- an
      # idle-but-live session is waiting on the operator and must be left
      # alone. A run that is already terminal has been completed by whatever
      # ended it, so this must not run twice.
      next unless session.ended? && session.run.active?

      Orchestrator::RunCompletion.call(
        run: session.run, outcome: session.outcome || "failed", summary: session.result
      )
      release_worktree(session.run)
    rescue Orchestrator::Herdr::Error => error
      # herdr itself is unreachable (not running, socket replaced). That says
      # nothing about this session in particular, so leave every row alone and
      # try again next minute rather than failing every run at once.
      Rails.logger.warn("RunSessionReconcileJob: #{error.message}")
      break
    end
  end

  private

  # The run is already completed, and the janitor's sweep retries a worktree
  # it could not remove, so one failed removal must not stop the sessions
  # still left in this loop.
  def release_worktree(run)
    Orchestrator::WorktreeJanitor.release!(run)
  rescue Orchestrator::WorktreeJanitor::Error => error
    Rails.logger.warn("RunSessionReconcileJob: could not release #{run.worktree_name}: #{error.message}")
  end
end
