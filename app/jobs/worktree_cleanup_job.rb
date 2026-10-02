# The janitor's periodic sweep: reclaims the worktrees of runs whose session
# is over and whose work is saved. See Orchestrator::WorktreeJanitor for the
# rules (only its own runs' worktrees, never the repository's checkout, never
# work that is not in the run's base branch or pushed; no age limit).
class WorktreeCleanupJob < ApplicationJob
  queue_as :default

  def perform
    removed = Orchestrator::WorktreeJanitor.sweep_all
    Rails.logger.info("WorktreeCleanupJob: reclaimed #{removed} worktree(s)") if removed.positive?
  end
end
