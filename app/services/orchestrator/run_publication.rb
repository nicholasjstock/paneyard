require "open3"

module Orchestrator
  # Turns a finished run's branch into a pull request, and cleans up once that
  # PR merges.
  #
  # There is no git-role worker any more. A session owns its worktree for the
  # whole run, so it commits and pushes its own branch as the last thing it
  # does (see RunPrompt's working agreement); Rails picks up from the pushed
  # branch and owns everything GitHub-facing, because PR content and merge
  # cleanup need to be deterministic rather than agent-authored.
  #
  # `gh` runs with a GitHub App installation token when one is configured --
  # scoped to this one repository/installation rather than the operator's
  # whole identity -- falling back to their ambient `gh auth` otherwise.
  module RunPublication
    class Error < StandardError; end
    module_function

    # Called by PublishRunJob after a session reports outcome "done". Owns the
    # run's final status: publication can fail, and a run whose branch never
    # reached GitHub is not a completed run.
    def publish!(run)
      return :unmanaged if run.worktree_name.blank?

      root = validated_root!(run)
      env = SessionEnv.git_env(run)

      if head_sha(root) == run.base_sha
        run.update!(
          publication_status: "no_changes", publication_completed_at: Time.current, publication_error: nil,
          status: "completed", stopped_at: run.stopped_at || Time.current
        )
        return :no_changes
      end

      push_branch!(root, run, env)
      url = run.pull_request_url.presence || publish_pull_request!(root, run, env)
      run.update!(
        publication_status: "awaiting_approval", pull_request_url: url,
        publication_completed_at: Time.current, publication_error: nil,
        status: "awaiting_review"
      )
      :published
    rescue StandardError => error
      record_failure!(run, error)
      raise error.is_a?(Error) ? error : Error.new(error.message)
    end

    def head_sha(root)
      git!(root, "rev-parse", "HEAD").strip
    end

    # The session is told to push before calling run_done, but a push is
    # cheap, idempotent ("Everything up-to-date"), and the alternative is
    # losing a whole run's work to one forgotten command.
    def push_branch!(root, run, env)
      _output, error, status = Open3.capture3(
        env, "git", "push", "-u", "origin", run.branch_name, chdir: root.to_s
      )
      raise Error, "git push failed: #{error}" unless status.success?
    end

    def publish_pull_request!(root, run, env)
      existing = existing_pull_request(root, run, env)
      if existing.present?
        update_existing_pull_request!(root, run, existing, env)
        return existing.fetch("url")
      end

      output, error, status = Open3.capture3(
        env, "gh", "pr", "create", "--base", "main", "--head", run.branch_name,
        "--title", pull_request_title(run), "--body", pull_request_body(run), chdir: root.to_s
      )
      raise Error, "gh pr create failed: #{error.presence || output}" unless status.success?

      output.strip
    end

    def existing_pull_request(root, run, env)
      output, _error, status = Open3.capture3(env, "gh", "pr", "view", run.branch_name, "--json", "url,isDraft", chdir: root.to_s)
      return nil unless status.success?

      details = JSON.parse(output)
      { "url" => details.fetch("url"), "isDraft" => details["isDraft"] }
    rescue JSON::ParserError, KeyError
      nil
    end

    # A run can reach publication twice: the operator or a PR reviewer sends
    # the session more work, it finishes again, and the same branch is already
    # open. Replace a draft's provisional body and make it reviewable; leave a
    # real PR's settled description alone and add the fresh summary as a
    # timeline comment instead.
    def update_existing_pull_request!(root, run, pull_request, env)
      url = pull_request.fetch("url")
      body = pull_request_body(run)
      if pull_request["isDraft"]
        _output, error, status = Open3.capture3(env, "gh", "pr", "edit", url, "--body", body, chdir: root.to_s)
        raise Error, "gh pr edit failed: #{error}" unless status.success?

        _output, error, status = Open3.capture3(env, "gh", "pr", "ready", url, chdir: root.to_s)
        raise Error, "gh pr ready failed: #{error}" unless status.success?
      else
        comment = post_comment!(root, url, "## Run finished again\n\n#{body}", env)
        RunOutboundComment.record!(run:, github_comment_id: comment.fetch("id"), kind: "publication_update")
      end
    end

    def pull_request_title(run)
      run.task.to_s.squish.truncate(120)
    end

    # run-summary.md is the one artifact Rails itself reads. The session is
    # told to write it for a reviewer; if it didn't, the PR still opens rather
    # than the whole publication failing over a missing file.
    def pull_request_body(run)
      ArtifactStore.read(run.target_root, run.run_id, "run-summary.md").presence ||
        "Automated workflow run: #{run.run_id}"
    rescue Errno::ENOENT
      "Automated workflow run: #{run.run_id}"
    end

    def merged?(run)
      env = SessionEnv.git_env(run)
      output, _error, status = Open3.capture3(env, "gh", "pr", "view", run.pull_request_url, "--json", "state", chdir: run.target_root)
      return false unless status.success?

      JSON.parse(output)["state"] == "MERGED"
    rescue JSON::ParserError, Errno::ENOENT
      false
    end

    # The one place a merged run's worktree is reclaimed. Everything else
    # (stopped, failed, abandoned) is WorktreeJanitor's job.
    def cleanup_merged_run!(run)
      merged = false
      run.with_lock do
        if run.publication_status == "merged"
          run.update!(status: "completed", stopped_at: run.stopped_at || Time.current)
          merged = true
          next
        end

        next unless merged?(run)

        root = validated_root!(run)
        source_root = Pathname(run.source_root)
        git!(source_root, "worktree", "remove", "--force", root.to_s)
        git!(source_root, "worktree", "prune")
        run.update!(
          publication_status: "merged", publication_error: nil,
          status: "completed", stopped_at: run.stopped_at || Time.current
        )
        SourceCheckoutSync.after_merge!(run)
        merged = true
      end
      merged ? :merged : :awaiting_confirmation
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def post_comment!(root, url, body, env = {})
      repository, number = repository_and_number(url)
      output, error, status = Open3.capture3(env, "gh", "api", "--method", "POST", "repos/#{repository}/issues/#{number}/comments", "-f", "body=#{body}", chdir: root.to_s)
      raise Error, "gh api comment failed: #{error.presence || output}" unless status.success?

      JSON.parse(output)
    end

    def repository_and_number(url)
      GitHubUrl.repository_and_number(url)
    rescue ArgumentError => error
      raise Error, error.message
    end

    def validated_root!(run)
      root = Pathname(run.target_root)
      raise Error, "Run worktree does not exist: #{root}" unless root.directory?
      raise Error, "Run has no publication branch" if run.branch_name.blank?
      if run.source_root.present? && root.expand_path == Pathname(run.source_root).expand_path
        raise Error, "Refusing to publish directly from the source checkout"
      end

      root
    end

    def record_failure!(run, error)
      return unless run.persisted?

      run.update!(publication_status: "failed", publication_error: error.message, status: "failed")
    end

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?

      raise Error, "git #{args.join(' ')} failed: #{error.presence || output}"
    end
  end
end
