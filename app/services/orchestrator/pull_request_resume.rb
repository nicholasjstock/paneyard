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
        if UserQuestion.exists?(run_id: run.run_id, github_comment_id: comment_id)
          run.update!(last_pull_request_comment_id: comment_id)
          return
        end

        author = comment.dig("user", "login") || "unknown"
        body = comment.fetch("body")
        answer_referenced_questions!(run, body, author)
        RunContext.upsert!(
          run_id: run.run_id, entry_key: "pr-comment-#{comment_id}", kind: "operator_decision", status: "confirmed",
          content: "Pull request comment from #{author}: #{body}", evidence_ref: comment["html_url"], created_by: "github_pr_comment"
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

    def answer_referenced_questions!(run, body, author)
      question_ids = body.to_s.scan(/\bQuestion\s+([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\s*:/i).flatten.uniq
      return if question_ids.empty?

      answer = body.to_s.sub(/\A\s*(?:Question\s+[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\s*:\s*)+/i, "").strip
      question_ids.each do |question_id|
        question = UserQuestion.find_by(run_id: run.run_id, question_id:, status: "open")
        question&.update!(status: "answered", answered_by: "github:#{author}", answered_at: Time.current, answer_text: answer)
      end
    end
    private_class_method :answer_referenced_questions!

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
