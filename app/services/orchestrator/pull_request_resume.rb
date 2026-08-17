require "open3"

module Orchestrator
  # Turns a reply on a run's pull request into more work for that run.
  #
  # This is the remote steering wheel, and the reason the whole
  # question/answer protocol could go: a reviewer's comment is just a prompt.
  # If the run's session is still live it goes straight into the pane; if it
  # has closed, a fresh session is started on the same worktree, resuming the
  # CLI's own conversation where possible so the agent still has the context
  # it built the first time.
  module PullRequestResume
    class Error < StandardError; end
    module_function

    # Logged at info on every poll (not just failures): this job silently
    # produced zero new comments for ~10 consecutive one-minute polls twice in
    # one session despite a real, unprocessed reply already sitting on the PR,
    # and no exception was ever raised -- gh api reported success each time.
    # Without a record of what gh actually returned, that gap is
    # unreproducible after the fact. Keep this until a recurrence is caught
    # with these fields and the actual cause found.
    def comments_after(run)
      env = SessionEnv.git_env(run)
      repository, number = repository_and_number(run.pull_request_url)
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

      parsed_output
        .select { |comment| comment.fetch("id").to_i > run.last_pull_request_comment_id.to_i }
        .sort_by { |comment| comment.fetch("id").to_i }
    rescue JSON::ParserError => error
      raise Error, "GitHub returned invalid PR comments: #{error.message}"
    end

    def safe_comment_ids(output)
      comments = JSON.parse(output)
      comments.is_a?(Array) ? comments.map { |comment| comment["id"] } : "<non-array>"
    rescue JSON::ParserError
      "<unparsable>"
    end

    def resume!(run, comment)
      comment_id = comment.fetch("id").to_s

      run.with_lock do
        return :already_processed if comment.fetch("id").to_i <= run.last_pull_request_comment_id.to_i
        return :merged if run.publication_status == "merged"

        # Never react to our own posts (publication updates, summaries).
        if RunOutboundComment.exists?(run_id: run.run_id, github_comment_id: comment_id)
          run.update!(last_pull_request_comment_id: comment_id)
          return :outbound_comment_skipped
        end

        run.update!(last_pull_request_comment_id: comment_id)
      end

      deliver!(run, comment)
    end

    def deliver!(run, comment)
      text = prompt_for(comment)
      session = run.live_session

      if session
        RunSessionRunner.prompt!(session, text)
        Rails.logger.info("PullRequestResume.resume run=#{run.run_id} outcome=prompted_live_session")
        return :prompted
      end

      reopen!(run, text)
    end

    # A closed session's CLI transcript still exists, so resume it rather than
    # starting cold: the agent keeps everything it learned building the branch
    # in the first place. cli_session_id comes from herdr's own agent.get
    # (agent_session), which is the only source of one for an interactive
    # session.
    def reopen!(run, text)
      previous = run.latest_session
      run.update!(status: "running", stopped_at: nil)
      RunSessionRunner.start!(run, resume_session_id: previous&.cli_session_id, prompt: text)
      Rails.logger.info("PullRequestResume.resume run=#{run.run_id} outcome=reopened_session")
      :reopened
    rescue RunSessionRunner::Error, Herdr::Error => error
      run.update!(status: "awaiting_review")
      raise Error, "Could not reopen a session for #{run.run_id}: #{error.message}"
    end

    def prompt_for(comment)
      author = comment.dig("user", "login") || "a reviewer"
      <<~PROMPT
        #{author} replied on this run's pull request:

        #{comment.fetch('body')}

        Act on it in this worktree, then push and call `run_done` again as usual. If it needs no code
        change, say so and call `run_done` with outcome `done`.
      PROMPT
    end

    def repository_and_number(url)
      GitHubUrl.repository_and_number(url)
    rescue ArgumentError => error
      raise Error, error.message
    end
  end
end
