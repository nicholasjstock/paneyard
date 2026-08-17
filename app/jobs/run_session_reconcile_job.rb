# The safety net behind run_done.
#
# A session is supposed to end by calling the run_done MCP tool, which carries
# a result and opens the pull request. This job covers every way that can fail
# to happen: the operator closed the pane by hand, the CLI crashed or was
# quit, herdr restarted. Without it those runs would hold their concurrency
# slot forever, since Rails learns nothing from a pane that simply stops
# existing.
#
# It also refreshes what herdr knows about each live session -- the agent
# status the run screen renders, and the CLI's own session id, which is the
# only way to obtain a --resume id for an interactive session.
class RunSessionReconcileJob < ApplicationJob
  queue_as :default

  def perform
    RunSession.live.includes(:run).find_each do |session|
      Orchestrator::RunSessionRunner.refresh!(session)

      # Only a session that refresh! just ended needs finishing off. A run
      # that is already terminal has been completed by whatever ended it
      # (usually run_done), so this must not run twice.
      next unless session.ended? && session.run.active?

      Orchestrator::RunCompletion.call(
        run: session.run, outcome: session.outcome || "failed", summary: session.result
      )
    rescue Orchestrator::Herdr::Error => error
      # herdr itself is unreachable (not running, socket replaced). That says
      # nothing about this session in particular, so leave every row alone and
      # try again next minute rather than failing every run at once.
      Rails.logger.warn("RunSessionReconcileJob: #{error.message}")
      break
    end
  end
end
