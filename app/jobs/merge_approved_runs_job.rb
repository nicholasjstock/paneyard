class MergeApprovedRunsJob < ApplicationJob
  queue_as :default

  def perform
    Run.where(publication_status: %w[published awaiting_approval cleanup_pushed]).find_each do |run|
      next unless Orchestrator::RunPublication.merged?(run)

      Orchestrator::RunPublication.cleanup_merged_run!(run)
    rescue Orchestrator::RunPublication::Error => error
      Rails.logger.warn("MergeApprovedRunsJob: run #{run.run_id}: #{error.message}")
    end
  end
end
