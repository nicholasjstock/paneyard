require "open3"

module Orchestrator
  module PullRequestResume
    class Error < StandardError; end
    module_function

    # Logged at info on every poll (not just failures): this job silently
    # produced zero new comments for ~10 consecutive one-minute polls twice
    # in one session despite a real, unprocessed reply already sitting on
    # the PR, and no exception was ever raised -- gh api reported success
    # each time. Without a record of what gh actually returned on each
    # poll, that gap is unreproducible after the fact. Keep this until a
    # recurrence is caught with these fields and the actual cause found.
    def comments_after(run)
      token = gh_token(run)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      repository, number = repository_and_number(run.conversation_url)
      endpoint = "repos/#{repository}/issues/#{number}/comments?per_page=100"
      output, error, status = Open3.capture3(env, "gh", "api", endpoint)
      Rails.logger.info(
        "PullRequestResume.comments_after run=#{run.run_id} last_comment_id=#{run.last_pull_request_comment_id.inspect} " \
        "gh_exit=#{status.exitstatus} gh_stderr=#{error.presence.inspect} raw_comment_ids=#{safe_comment_ids(output)}"
      )
      parsed_output = JSON.parse(output)
      unless parsed_output.is_a?(Array)
        Rails.logger.warn("PullRequestResume.comments_after run=#{run.run_id}: GitHub returned a non-array comments response; skipping")
        return []
      end

      raise Error, "gh api comments failed: #{error}" unless status.success?

      parsed_output.select { |comment| comment.fetch("id").to_i > run.last_pull_request_comment_id.to_i }.sort_by { |comment| comment.fetch("id").to_i }
    rescue JSON::ParserError => error
      raise Error, "GitHub returned invalid PR comments: #{error.message}"
    end

    def safe_comment_ids(output)
      comments = JSON.parse(output)
      comments.is_a?(Array) ? comments.map { |comment| comment["id"] } : "<non-array>"
    rescue JSON::ParserError
      "<unparsable>"
    end
    private_class_method :safe_comment_ids

    # A PR comment can only resume a run by answering its one open blocking
    # question -- never unconditionally. Every run reachable via PR comments
    # (awaiting_user_feedback or completed-and-published) is expected to always
    # have exactly one open blocking UserQuestion (see
    # Orchestrator::RunPublication#open_review_question! for the completed
    # case, and Orchestrator::ApplyChaperoneDecision for the blocked case),
    # so "the sole open blocking question" is a safe implicit target when
    # the comment doesn't reference one by id.
    def resume!(run, comment)
      run.with_lock do
        if comment.fetch("id").to_i <= run.last_pull_request_comment_id.to_i
          Rails.logger.info("PullRequestResume.resume run=#{run.run_id} comment=#{comment.fetch('id')} outcome=already_processed")
          return
        end
        raise Error, "Cannot resume a merged run" if run.publication_status == "merged"

        comment_id = comment.fetch("id").to_s
        if UserQuestion.exists?(run_id: run.run_id, github_comment_id: comment_id)
          run.update!(last_pull_request_comment_id: comment_id)
          Rails.logger.info("PullRequestResume.resume run=#{run.run_id} comment=#{comment_id} outcome=system_question_skipped")
          return
        end

        author = comment.dig("user", "login") || "unknown"
        body = comment.fetch("body")

        # A reply answering the run's plan-approval question is never
        # mechanically "answered" the way an ordinary blocking question is:
        # unblocking dispatch here is itself the consequential action this
        # gate exists to protect (see agent_personas/reply_received.md), so
        # the reply's content must be classified by that bounded review
        # before anything unblocks -- never inferred from a magic phrase.
        plan_approval_question = run.user_questions.open_only.where(priority: "blocking").plan_approval.first
        if plan_approval_question
          Orchestrator::ReplyReceivedTrigger.call(question: plan_approval_question, comment: comment)
          RunContext.upsert!(
            run_id: run.run_id, entry_key: "conversation-comment-#{comment_id}", kind: "operator_decision", status: "confirmed",
            content: "GitHub comment from #{author}: #{body}", evidence_ref: comment["html_url"], created_by: "github_pr_comment"
          )
          run.update!(last_pull_request_comment_id: comment_id)
          Rails.logger.info("PullRequestResume.resume run=#{run.run_id} comment=#{comment_id} outcome=routed_to_reply_received")
          return
        end

        answered_any, unmatched_ids = apply_comment_to_questions!(run, body, author)

        RunContext.upsert!(
          run_id: run.run_id, entry_key: "conversation-comment-#{comment_id}", kind: "operator_decision", status: "confirmed",
          content: "GitHub comment from #{author}: #{body}", evidence_ref: comment["html_url"], created_by: "github_pr_comment"
        )
        run.update!(last_pull_request_comment_id: comment_id)

        remaining = run.user_questions.open_only.where(priority: "blocking").order(:asked_at).to_a
        if answered_any && remaining.empty?
          run.update!(status: "running", stopped_at: nil)
          # A published run's branch may have drifted from main since the PR
          # was opened -- always reconcile it, regardless of what the comment
          # says. This is cheap and idempotent (a no-op commit/rebase when
          # nothing has changed), so there is no wording to match and nothing
          # for the operator to get "just right": no magic phrase, just an
          # always-safe check. The comment still goes to the planner too
          # (below) in case it also asks for further work.
          if run.pull_request_url.present?
            Orchestrator::RunPublication.queue_worker!(run)
          else
            run.update!(publication_status: "resume_requested")
          end
          SpawnRequest.create!(
            run_id: run.run_id, asked_by: "github_pr_comment", requested_role: "planner", priority: "blocking",
            scope: "workflow-plan.md", text: "A new pull request comment requests that this run continue. Incorporate the comment as the current operator instruction and plan the next bounded step. " \
              "If the branch needed reconciling with main, Rails already triggered that separately through the terminal git worker -- do not propose git/commit/rebase work yourself.",
            context: "GitHub comment ##{comment_id} from #{author}: #{body}", tags: %w[github pr-comment resume]
          )
          run.publish_phase!(phase: "planning", owner: "github", summary: "Resuming from pull request comment ##{comment_id}.")
          Rails.logger.info("PullRequestResume.resume run=#{run.run_id} comment=#{comment_id} outcome=resumed")
        else
          reply_comment_id = post_reply!(run, unresolved_explanation(unmatched_ids:, remaining:))
          run.update!(last_pull_request_comment_id: [ comment_id.to_i, reply_comment_id.to_i ].max.to_s)
          Rails.logger.info(
            "PullRequestResume.resume run=#{run.run_id} comment=#{comment_id} outcome=unresolved " \
            "remaining_questions=#{remaining.size} reply_comment=#{reply_comment_id}"
          )
        end
      end
    end

    # Explicit references (`Question <uuid>: ...`) are matched against every
    # open question, not only blocking ones -- an advisory (non-blocking)
    # question is still answerable by id. Only open blocking questions are
    # eligible for the implicit, no-id-given fallback: answering "the"
    # question a comment is obviously replying to only makes sense when
    # there is exactly one candidate.
    def apply_comment_to_questions!(run, body, author)
      explicit_ids = body.to_s.scan(/\bQuestion\s+([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\s*:/i).flatten.uniq
      answered_any = false
      unmatched_ids = []

      if explicit_ids.any?
        answer = body.to_s.sub(/\A\s*(?:Question\s+[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\s*:\s*)+/i, "").strip
        explicit_ids.each do |question_id|
          question = UserQuestion.find_by(run_id: run.run_id, question_id:, status: "open")
          if question
            question.update!(status: "answered", answered_by: "github:#{author}", answered_at: Time.current, answer_text: answer)
            answered_any = true
          else
            unmatched_ids << question_id
          end
        end
      else
        # At most one open blocking question ever exists per run (see
        # Run#open_blocking_question?), so this scope holds 0 or 1 rows in
        # practice -- guard on .one? anyway rather than assuming that
        # invariant holds everywhere it's supposed to.
        open_blocking = run.user_questions.open_only.where(priority: "blocking").to_a
        if open_blocking.one?
          open_blocking.first.update!(status: "answered", answered_by: "github:#{author}", answered_at: Time.current, answer_text: body.to_s.strip)
          answered_any = true
        end
      end

      [ answered_any, unmatched_ids ]
    end
    private_class_method :apply_comment_to_questions!

    def unresolved_explanation(unmatched_ids:, remaining:)
      parts = []
      if unmatched_ids.any?
        verb = unmatched_ids.size > 1 ? "aren't" : "isn't"
        parts << "Question#{'s' if unmatched_ids.size > 1} #{unmatched_ids.join(', ')} #{verb} open on this run."
      end

      parts << if remaining.empty?
        "There's no open question on this run right now, so there's nothing to resume."
      elsif remaining.one?
        "This run is still waiting on Question #{remaining.first.question_id}: #{remaining.first.text}"
      else
        list = remaining.map { |question| "- Question #{question.question_id}: #{question.text}" }.join("\n")
        "This run has more than one open question -- reply with `Question <id>: <answer>` naming one:\n\n#{list}"
      end

      parts.join(" ")
    end
    private_class_method :unresolved_explanation

    def post_reply!(run, body)
      token = gh_token(run)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      repository, number = repository_and_number(run.conversation_url)
      output, error, status = Open3.capture3(env, "gh", "api", "--method", "POST", "repos/#{repository}/issues/#{number}/comments", "-f", "body=#{body}")
      raise Error, "gh api comment failed: #{error.presence || output}" unless status.success?

      JSON.parse(output).fetch("id").to_s
    rescue JSON::ParserError, KeyError => error
      raise Error, "GitHub returned an invalid posted comment: #{error.message}"
    end
    # Not private: Orchestrator::ApplyReplyReceivedDecision also posts to a
    # run's conversation (an explain reply), reusing the same gh/token/URL
    # plumbing instead of duplicating it.

    # Edits an already-posted comment in place -- used by
    # Orchestrator::PlanApprovalQuestion to upgrade a plan-approval question
    # with its reporter's plain-language summary once that finishes, without
    # waiting on it to post the question in the first place.
    def patch_comment!(run, comment_id, body)
      token = gh_token(run)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      repository, = repository_and_number(run.conversation_url)
      _output, error, status = Open3.capture3(env, "gh", "api", "--method", "PATCH", "repos/#{repository}/issues/comments/#{comment_id}", "-f", "body=#{body}")
      raise Error, "gh api comment edit failed: #{error.presence}" unless status.success?
    end

    def repository_and_number(url)
      GitHubUrl.repository_and_number(url)
    rescue ArgumentError => error
      raise Error, error.message
    end
    private_class_method :repository_and_number

    def gh_token(run)
      return "" unless GitHubAppAuth.app_configured?

      GitHubAppAuth.installation_token_for(workspace_root: run.target_root)
    rescue GitHubAppAuth::Error => e
      Rails.logger.warn "Failed to get GitHub App token: #{e.message}"
      ""
    end
    private_class_method :gh_token
  end
end
