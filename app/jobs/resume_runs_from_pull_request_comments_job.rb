class ResumeRunsFromPullRequestCommentsJob < ApplicationJob
  queue_as :default

  def perform
    # A plain .where.not(publication_status: "merged") would silently drop
    # rows where it is NULL, since SQL's != never matches NULL.
    Run.where.not(pull_request_url: nil)
      .where("publication_status IS NULL OR publication_status != ?", "merged").find_each do |run|
      comments = Orchestrator::PullRequestResume.comments_after(run)
      Rails.logger.info(
        "ResumeRunsFromPullRequestCommentsJob run=#{run.run_id} comments_to_process=#{comments.size} " \
        "comment_ids=#{comments.map { |comment| comment['id'] }.join(',')}"
      )
      comments.each do |comment|
        Orchestrator::PullRequestResume.resume!(run, comment)
      end
    rescue Orchestrator::PullRequestResume::Error => error
      Rails.logger.warn("ResumeRunsFromPullRequestCommentsJob: run #{run.run_id}: #{error.message}")
    end
  end
end
