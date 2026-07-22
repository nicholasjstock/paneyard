require "open3"
require "uri"

module Orchestrator
  module PullRequestResume
    class Error < StandardError; end
    module_function

    def comments_after(run)
      repository, number = repository_and_number(run)
      endpoint = "repos/#{repository}/issues/#{number}/comments?per_page=100"
      output, error, status = Open3.capture3("gh", "api", endpoint)
      raise Error, "gh api comments failed: #{error}" unless status.success?

      comments = JSON.parse(output)
      comments.select { |comment| comment.fetch("id").to_i > run.last_pull_request_comment_id.to_i }.sort_by { |comment| comment.fetch("id").to_i }
    rescue JSON::ParserError => error
      raise Error, "GitHub returned invalid PR comments: #{error.message}"
    end

    def resume!(run, comment)
      run.with_lock do
        return if comment.fetch("id").to_i <= run.last_pull_request_comment_id.to_i
        raise Error, "Cannot resume a merged run" if run.publication_status == "merged"

        comment_id = comment.fetch("id").to_s
        author = comment.dig("user", "login") || "unknown"
        body = comment.fetch("body")
        RunContext.upsert!(
          run_id: run.run_id, entry_key: "pr-comment-#{comment_id}", kind: "operator_decision", status: "confirmed",
          content: "Pull request comment from #{author}: #{body}", evidence_ref: nil, created_by: "github_pr_comment"
        )
        run.update!(status: "running", stopped_at: nil, publication_status: "resume_requested", last_pull_request_comment_id: comment_id)
        SpawnRequest.create!(
          run_id: run.run_id, asked_by: "github_pr_comment", requested_role: "planner", priority: "blocking",
          scope: "workflow-plan.md", text: "A new pull request comment requests that this run continue. Incorporate the comment as the current operator instruction and plan the next bounded step.",
          context: "GitHub comment ##{comment_id} from #{author}: #{body}", tags: %w[github pr-comment resume]
        )
        run.publish_phase!(phase: "planning", owner: "github", summary: "Resuming from pull request comment ##{comment_id}.")
      end
    end

    def repository_and_number(run)
      uri = URI.parse(run.pull_request_url)
      parts = uri.path.split("/").reject(&:blank?)
      raise Error, "Invalid pull request URL: #{run.pull_request_url}" unless parts.length >= 4 && parts[-2] == "pull"

      [ parts.first(2).join("/"), parts.last ]
    rescue URI::InvalidURIError
      raise Error, "Invalid pull request URL: #{run.pull_request_url}"
    end
    private_class_method :repository_and_number
  end
end
