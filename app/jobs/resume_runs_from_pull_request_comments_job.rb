class ResumeRunsFromPullRequestCommentsJob < ApplicationJob
  queue_as :default

  def perform
    Run.where.not(pull_request_url: nil).where.not(publication_status: "merged").find_each do |run|
      Orchestrator::PullRequestResume.comments_after(run).each do |comment|
        Orchestrator::PullRequestResume.resume!(run, comment)
      end
    rescue Orchestrator::PullRequestResume::Error => error
      Rails.logger.warn("ResumeRunsFromPullRequestCommentsJob: run #{run.run_id}: #{error.message}")
    end
  end
end
