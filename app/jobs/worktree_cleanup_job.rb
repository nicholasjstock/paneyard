# Reclaims worktrees for runs that have been terminal long enough, and for
# orphans no run owns. See Orchestrator::WorktreeJanitor for the safety rules
# (never `main`, never work that is not pushed or merged).
class WorktreeCleanupJob < ApplicationJob
  queue_as :default

  def perform
    removed = Orchestrator::WorktreeJanitor.sweep_all
    Rails.logger.info("WorktreeCleanupJob: reclaimed #{removed} worktree(s)") if removed.positive?
  end
end
