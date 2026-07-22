class MergeApprovedRunsJob < ApplicationJob
  queue_as :default

  def perform
    Run.where(publication_status: %w[published awaiting_approval cleanup_pushed]).find_each do |run|
      if run.publication_status.in?(%w[published awaiting_approval])
        next unless Orchestrator::RunPublication.approved?(run)

        Orchestrator::RunPublication.remove_evidence!(run)
      else
        Orchestrator::RunPublication.merge_and_cleanup!(run)
      end
    rescue Orchestrator::RunPublication::Error => error
      Rails.logger.warn("MergeApprovedRunsJob: run #{run.run_id}: #{error.message}")
    end
  end
end
