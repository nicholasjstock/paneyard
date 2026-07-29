require "open3"

module Orchestrator
  module RunPublication
    class Error < StandardError; end
    module_function

    # Commit, conflict repair, rebase, and push are owned by the
    # terminal "git" worker (see agent_personas/git.md) -- the one role with
    # real .git write access. The worker commits, rebases, and pushes; Rails
    # owns GitHub publication so PR content and issue linkage are deterministic.
    # This module persists the worker outcome (via McpTools::FinalizeRunPublicationTool) and owns
    # the git operations that are unrelated to that finalize lifecycle: the
    # mid-run blocking-question conversation (an issue before real code
    # exists, linked from the PR once one does -- see ensure_conversation_issue!/
    # publish_question!/link_conversation_issue!), and post-merge cleanup.

    # Single dispatch point for the git worker -- used by TickRunJob once a
    # run's other finalization workers (seeder/reporter/curator/demo) are
    # done, by PullRequestResume's "fix the merge conflicts" comment
    # shortcut, by GitPublicationRecovery's direct requeue after a blocked
    # attempt, and by the operator's retry_publication action. One spawn
    # drives the entire commit -> conflict repair -> rebase -> push sequence
    # itself (see the persona), so there is nothing left for Rails
    # to loop on the way the old MergeConflictResolution state machine did.
    #
    # Always starts on the small model tier, same as any other planning/
    # worker dispatch -- it is never hardcoded to "strong" here. A repeated
    # failure on this run's git lineage crosses ChaperoneTrigger's normal
    # threshold exactly like any other worker's, and the resulting
    # strong-model chaperone review decides whether to continue small,
    # promote, or stop; nothing about publication work gets a standing
    # exception from that judgment call.
    # Guards only against a duplicate *open* request, not a still-"running"
    # prior git worker -- the same shape as VerifierRecovery#requeue!. A
    # worker that just reported [BLOCKED] via worker_turn is expected to
    # exit immediately after, but its Worker row only flips to "stopped"
    # once WorkerReconcileJob later observes the dead process; blocking on
    # that here would delay recovery by a full reconcile cycle for no
    # safety benefit, since actual process dispatch is already single-flight
    # per run (see SpawnRequestedWorkers).
    def queue_worker!(run)
      return if SpawnRequest.where(run_id: run.run_id, requested_role: "git", status: "open").exists?

      validated_root!(run)
      run.update!(publication_status: "commit_pending", publication_error: nil)
      # "Begin." is deliberate -- agent_personas/git.md is auto-prepended to
      # every git-role spawn and already states the full commit/rebase/push
      # sequence in far more detail than fit here; this used to
      # restate a condensed version of it by hand, with nothing keeping the
      # two in sync.
      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "orchestrator", requested_role: "git", priority: "blocking",
        scope: "publish-#{run.worktree_name}.md", execution_mode: "implementation", write_scope: "git_managed",
        allowed_paths: [ "**/*" ], model_tier: "small", text: "Begin."
      )
      run.publish_phase!(phase: "committing", owner: "orchestrator", summary: "The git worker is committing, rebasing, and publishing this run.")
    end

    def finalize!(run, outcome:, error: nil)
      return :unmanaged if run.worktree_name.blank?

      run.with_lock do
        case outcome.to_s
        when "published"
          upload_review_assets!(run)
          pull_request_url = run.pull_request_url.presence || publish_pull_request!(run)
          run.update!(
            publication_status: "awaiting_approval", pull_request_url: pull_request_url,
            conversation_pr_status: "ready", publication_completed_at: Time.current, publication_error: nil,
            status: "completed", stopped_at: run.stopped_at || Time.current
          )
          link_conversation_issue!(run) if run.github_issue_url.present?
          open_review_question!(run)
        when "no_changes"
          run.update!(
            publication_status: "no_changes", publication_completed_at: Time.current, publication_error: nil,
            status: "completed", stopped_at: run.stopped_at || Time.current
          )
        when "failed"
          run.update!(publication_status: "failed", publication_error: error.presence || "git worker reported failure", status: "failed")
        else
          raise Error, "Unknown publication outcome: #{outcome.inspect}"
        end
      end

      run.publish_phase!(phase: finalize_phase(outcome), owner: "orchestrator", summary: finalize_summary(run, outcome))
      outcome.to_s.to_sym
    end

    def finalize_phase(outcome)
      outcome.to_s == "failed" ? "failed" : "completed"
    end
    private_class_method :finalize_phase

    def finalize_summary(run, outcome)
      case outcome.to_s
      when "published" then "Pull request ready for review: #{run.pull_request_url}"
      when "no_changes" then "Run completed with no source changes; no PR was created."
      when "failed" then "PR publication failed: #{run.publication_error}"
      end
    end
    private_class_method :finalize_summary

    # The curator only selects local files. Rails performs the GitHub release
    # upload after the git worker has pushed, so no worker needs `gh` access.
    # A retried finalization uploads only assets that do not already have a
    # persisted public URL.
    def upload_review_assets!(run)
      assets = run.review_assets.where(github_url: nil).to_a
      return if assets.empty?

      root = validated_root!(run)
      paths = assets.map { |asset| review_asset_path!(root, asset) }
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      tag = "workflow-evidence-#{run.run_id}"

      _output, _error, view_status = Open3.capture3(env, "gh", "release", "view", tag, "--json", "url", chdir: root.to_s)
      command = if view_status.success?
        [ "gh", "release", "upload", tag, *paths ]
      else
        [ "gh", "release", "create", tag, "--draft", "--target", run.branch_name, *paths ]
      end
      output, error, status = Open3.capture3(env, *command, chdir: root.to_s)
      raise Error, "gh release upload failed: #{error.presence || output}" unless status.success?

      output, error, status = Open3.capture3(env, "gh", "release", "view", tag, "--json", "assets", chdir: root.to_s)
      raise Error, "gh release view failed: #{error.presence || output}" unless status.success?

      uploaded = JSON.parse(output).fetch("assets").index_by { |asset| asset.fetch("name") }
      assets.each do |asset|
        uploaded_asset = uploaded[File.basename(asset.workspace_path)]
        url = uploaded_asset&.fetch("url", nil) || uploaded_asset&.fetch("downloadUrl", nil)
        raise Error, "GitHub release did not return an upload URL for #{asset.workspace_path}" if url.blank?

        asset.update!(github_url: url)
      end
    rescue JSON::ParserError, KeyError => error
      raise Error, "gh release returned invalid asset metadata: #{error.message}"
    end
    private_class_method :upload_review_assets!

    def review_asset_path!(root, asset)
      path = root.join(asset.workspace_path).cleanpath
      raise Error, "Review asset is missing: #{asset.workspace_path}" unless path.file?
      raise Error, "Review asset is outside the run worktree: #{asset.workspace_path}" unless path.to_s.start_with?("#{root}/")

      path.to_s
    end
    private_class_method :review_asset_path!

    def publish_pull_request!(run)
      root = validated_root!(run)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      existing_pull_request = existing_pull_request(root, run, env)
      if existing_pull_request.present?
        update_existing_pull_request!(root, run, existing_pull_request, env)
        return existing_pull_request.fetch("url")
      end

      output, error, status = Open3.capture3(
        env, "gh", "pr", "create", "--base", "main", "--head", run.branch_name,
        "--title", pull_request_title(run), "--body", pull_request_body(run), chdir: root.to_s
      )
      raise Error, "gh pr create failed: #{error.presence || output}" unless status.success?

      output.strip
    end
    private_class_method :publish_pull_request!

    def existing_pull_request(root, run, env)
      output, _error, status = Open3.capture3(env, "gh", "pr", "view", run.branch_name, "--json", "url,isDraft", chdir: root.to_s)
      return nil unless status.success?

      details = JSON.parse(output)
      { "url" => details.fetch("url"), "isDraft" => details["isDraft"] }
    rescue JSON::ParserError, KeyError
      nil
    end
    private_class_method :existing_pull_request

    # A pre-existing draft is a pre-code conversation vessel, so replace its
    # provisional body and make it reviewable. A real PR keeps its settled
    # description; a rerun adds fresh information as a timeline comment.
    def update_existing_pull_request!(root, run, pull_request, env)
      url = pull_request.fetch("url")
      body = pull_request_body(run)
      if pull_request["isDraft"]
        _output, error, status = Open3.capture3(env, "gh", "pr", "edit", url, "--body", body, chdir: root.to_s)
        raise Error, "gh pr edit failed: #{error}" unless status.success?

        _output, error, status = Open3.capture3(env, "gh", "pr", "ready", url, chdir: root.to_s)
        raise Error, "gh pr ready failed: #{error}" unless status.success?
      else
        post_comment!(root, url, "## Run finished again\n\n#{body}")
      end
    end
    private_class_method :update_existing_pull_request!

    def pull_request_title(run)
      run.task.to_s.squish.truncate(120)
    end
    private_class_method :pull_request_title

    def pull_request_body(run)
      ArtifactStore.read(run.target_root, run.run_id, "run-summary.md").presence ||
        "Automated workflow run: #{run.run_id}"
    rescue Errno::ENOENT
      "Automated workflow run: #{run.run_id}"
    end
    private_class_method :pull_request_body

    # Posts to whichever GitHub object currently carries this run's
    # conversation: the PR if one already exists, otherwise an issue (opened
    # on demand -- see ensure_conversation_issue!). A run's conversation
    # never needs a PR just to ask a question; only real code changes
    # warrant one, and finalize! moves the conversation there itself once
    # that happens.
    def publish_question!(question)
      return :unmanaged unless question.run&.managed_worktree?

      question.with_lock do
        return :published if question.github_comment_id.present?

        run = question.run
        url = run.pull_request_url.presence || ensure_conversation_issue!(run)
        root = validated_root!(run)
        comment = post_comment!(root, url, build_question_body(question))
        question.update!(github_comment_id: comment.fetch("id").to_s, github_comment_url: comment["html_url"], github_published_at: Time.current, github_publication_error: nil)
        :published
      end
    rescue StandardError => error
      question.update!(github_publication_error: error.message) if question.persisted?
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def build_question_body(question)
      <<~MARKDOWN
        ## Workflow question #{question.question_id}

        #{question.text}

        #{question.context.presence || "No additional context was supplied."}

        Just reply to answer and resume the run. If more than one question is open at once, reference this one explicitly with `Question #{question.question_id}: <your answer>` so it's clear which one you're answering.
      MARKDOWN
    end
    # Not private: Orchestrator::PlanApprovalQuestion re-renders this same
    # format to PATCH an already-posted plan-approval comment once its
    # question.text is upgraded with the reporter's plain-language summary.

    # An issue needs no branch or commit -- it exists purely to carry
    # conversation before there's anything to diff yet. finalize! links it
    # from the PR, so GitHub closes it when that PR merges.
    def ensure_conversation_issue!(run)
      return run.github_issue_url if run.github_issue_url.present?

      run.with_lock do
        return run.reload.github_issue_url if run.github_issue_url.present?

        root = validated_root!(run)
        run.update!(github_issue_status: "publishing", publication_error: nil)
        url = create_issue(root, run)
        run.update!(github_issue_url: url, github_issue_status: "open")
        url
      end
    rescue StandardError => error
      run.update!(github_issue_status: "failed", publication_error: error.message) if run.persisted?
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def create_issue(root, run)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      args = [ "gh", "issue", "create", "--title", run.task.to_s.truncate(120), "--body", build_issue_body(run) ]
      output, error, status = Open3.capture3(env, *args, chdir: root.to_s)
      raise Error, "gh issue create failed: #{error.presence || output}" unless status.success?

      output.strip
    end
    private_class_method :create_issue

    def build_issue_body(run)
      "Automated workflow run: #{run.run_id}\n\nWorktree: #{run.worktree_name}\n\n" \
      "This conversation will move to a pull request once real code changes exist."
    end
    private_class_method :build_issue_body

    # Add GitHub's closing keyword to the PR body. This creates the native
    # issue↔PR relationship and leaves the issue open through review; GitHub
    # closes it automatically when the PR merges. A transient edit failure
    # must not invalidate an otherwise published PR.
    def link_conversation_issue!(run)
      root = validated_root!(run)
      _repository, issue_number = repository_and_number(run.github_issue_url)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      output, error, status = Open3.capture3(env, "gh", "pr", "view", run.pull_request_url, "--json", "body", chdir: root.to_s)
      raise Error, "gh pr view failed: #{error.presence || output}" unless status.success?

      body = JSON.parse(output).fetch("body").to_s
      reference = "Closes ##{issue_number}"
      return if body.match?(/\bcloses\s+##{Regexp.escape(issue_number)}\b/i)

      _output, edit_error, edit_status = Open3.capture3(
        env, "gh", "pr", "edit", run.pull_request_url, "--body", [ body.presence, reference ].compact.join("\n\n"), chdir: root.to_s
      )
      raise Error, "gh pr edit failed: #{edit_error}" unless edit_status.success?
    rescue JSON::ParserError, KeyError => error
      Rails.logger.warn("RunPublication.link_conversation_issue! run=#{run.run_id} returned an invalid pull request body: #{error.message}")
    rescue Error => error
      Rails.logger.warn("RunPublication.link_conversation_issue! run=#{run.run_id} failed: #{error.message}")
    end
    private_class_method :link_conversation_issue!

    # Best-effort only -- GitHub normally closes the linked issue when the PR
    # merges, but explicitly close it during post-merge cleanup as a fallback
    # and keep Rails' stored issue state accurate.
    def close_conversation_issue!(run)
      return if run.github_issue_url.blank? || run.github_issue_status == "closed"

      root = validated_root!(run)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      _output, error, status = Open3.capture3(
        env, "gh", "issue", "close", run.github_issue_url, "--comment", "Merged in #{run.pull_request_url}", chdir: root.to_s
      )
      Rails.logger.warn("RunPublication.close_conversation_issue! run=#{run.run_id} failed: #{error}") unless status.success?
      run.update!(github_issue_status: "closed")
    end
    private_class_method :close_conversation_issue!

    def merged?(run)
      token = gh_token(Pathname(run.target_root))
      env = token.present? ? { "GH_TOKEN" => token } : {}
      output, _error, status = Open3.capture3(env, "gh", "pr", "view", run.pull_request_url, "--json", "state", chdir: run.target_root)
      return false unless status.success?

      details = JSON.parse(output)
      details["state"] == "MERGED"
    rescue JSON::ParserError, Errno::ENOENT
      false
    end

    def cleanup_merged_run!(run)
      run.with_lock do
        return :merged if run.publication_status == "merged"

        root = validated_root!(run)
        source_root = Pathname(run.source_root)
        rebase_main_onto_origin!(source_root)
        close_conversation_issue!(run)
        delete_review_release!(root, run) if run.review_assets.any?
        git!(source_root, "worktree", "remove", "--force", root.to_s)
        git!(source_root, "worktree", "prune")
        run.update!(publication_status: "merged", publication_error: nil)
        :merged
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def post_comment!(root, url, body)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      repository, number = repository_and_number(url)
      output, error, status = Open3.capture3(env, "gh", "api", "--method", "POST", "repos/#{repository}/issues/#{number}/comments", "-f", "body=#{body}", chdir: root.to_s)
      raise Error, "gh api comment failed: #{error.presence || output}" unless status.success?

      JSON.parse(output)
    end
    private_class_method :post_comment!

    def delete_review_release!(root, run)
      token = gh_token(root)
      env = token.present? ? { "GH_TOKEN" => token } : {}
      tag = "workflow-evidence-#{run.run_id}"
      _output, _error, status = Open3.capture3(env, "gh", "release", "delete", tag, "--yes", "--cleanup-tag", chdir: root.to_s)
      raise Error, "gh release delete failed" unless status.success?
    end
    private_class_method :delete_review_release!

    def rebase_main_onto_origin!(source_root)
      branch = git!(source_root, "branch", "--show-current").strip
      raise Error, "Source checkout must be on main before cleanup; found #{branch.presence || "detached HEAD"}" unless branch == "main"

      git!(source_root, "fetch", "origin", "main")
      git!(source_root, "rebase", "origin/main")
    end
    private_class_method :rebase_main_onto_origin!

    def repository_and_number(url)
      GitHubUrl.repository_and_number(url)
    rescue ArgumentError => error
      raise Error, error.message
    end
    private_class_method :repository_and_number

    def validated_root!(run)
      root = Pathname(run.target_root)
      raise Error, "Run worktree does not exist: #{root}" unless root.directory?
      raise Error, "Run has no publication branch" if run.branch_name.blank?
      if run.source_root.present? && root.expand_path == Pathname(run.source_root).expand_path
        raise Error, "Refusing to publish directly from the source checkout"
      end

      root
    end
    private_class_method :validated_root!

    def record_failure!(run, error)
      run.update!(publication_status: "failed", publication_error: error.message) if run.persisted?
    end
    private_class_method :record_failure!

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?

      raise Error, "git #{args.join(' ')} failed: #{error.presence || output}"
    end

    # Ported verbatim from the "open_review_question!" step of the removed
    # FinalizeRunPublicationJob: a published PR has nothing open to answer
    # unless something asked a question, but a completed run needs one too,
    # to give a reviewer's "this isn't actually done" PR comment the same
    # mechanism a chaperone-raised block already has. Idempotent: a retried
    # finalize call must not pile up duplicate review questions.
    def open_review_question!(run)
      return if run.open_blocking_question?

      UserQuestion.create!(
        run_id: run.run_id, asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking",
        text: "This run's work is ready for review. Reply on this PR to continue the run with further " \
              "instructions, or approve/merge if it's complete."
      )
    end
    private_class_method :open_review_question!

    # Get GitHub App installation token for authenticating gh CLI calls.
    # Falls back to no token if GitHub App is not configured.
    def gh_token(root)
      return "" unless GitHubAppAuth.app_configured?

      GitHubAppAuth.installation_token_for(workspace_root: root.to_s)
    rescue GitHubAppAuth::Error => e
      Rails.logger.warn "Failed to get GitHub App token: #{e.message}"
      ""
    end
    private_class_method :gh_token
  end
end
