require "open3"
require "uri"

module Orchestrator
  module RunPublication
    class Error < StandardError; end
    module_function

    # Commit, conflict repair, rebase, and push/PR creation are owned by the
    # terminal "git" worker (see .claude/agents/git.md) -- the one role with
    # real .git write access, driving those git/gh commands itself instead of
    # Rails guessing on its behalf. This module now only persists the outcome
    # that worker reports (via McpTools::FinalizeRunPublicationTool) and owns
    # the git operations that are unrelated to that finalize lifecycle: the
    # mid-run blocking-question draft PR, and post-merge cleanup.

    # Single dispatch point for the git worker -- used by TickRunJob once a
    # run's other finalization workers (seeder/reporter/curator/demo) are
    # done, by PullRequestResume's "fix the merge conflicts" comment
    # shortcut, by GitPublicationRecovery's direct requeue after a blocked
    # attempt, and by the operator's retry_publication action. One spawn
    # drives the entire commit -> conflict repair -> rebase -> push -> PR
    # sequence itself (see the persona), so there is nothing left for Rails
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
      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "orchestrator", requested_role: "git", priority: "blocking",
        scope: "publish-#{run.worktree_name}.md", execution_mode: "implementation", write_scope: "git_managed",
        allowed_paths: [ "**/*" ], model_tier: "small",
        text: "Commit this run's changes, rebase onto origin/main (resolving any conflicts yourself with real git " \
          "access), push, and create or update the pull request. Call finalize_run_publication exactly once when done."
      )
      run.publish_phase!(phase: "committing", owner: "orchestrator", summary: "The git worker is committing, rebasing, and publishing this run.")
    end

    def finalize!(run, outcome:, pull_request_url: nil, error: nil, review_assets: [])
      return :unmanaged if run.worktree_name.blank?

      run.with_lock do
        case outcome.to_s
        when "published"
          run.update!(
            publication_status: "awaiting_approval", pull_request_url: pull_request_url,
            conversation_pr_status: "ready", publication_completed_at: Time.current, publication_error: nil,
            status: "completed", stopped_at: run.stopped_at || Time.current
          )
          apply_review_asset_urls!(run, review_assets)
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

    def apply_review_asset_urls!(run, review_assets)
      Array(review_assets).each do |asset|
        path = asset[:workspacePath] || asset["workspacePath"]
        url = asset[:githubUrl] || asset["githubUrl"]
        next if path.blank? || url.blank?

        run.review_assets.where(workspace_path: path).update_all(github_url: url)
      end
    end
    private_class_method :apply_review_asset_urls!

    # A question is sufficient reason to establish the run's shared GitHub
    # conversation. A clean branch receives an empty commit because GitHub
    # cannot open a PR for a branch identical to its base. This is a small,
    # low-risk git write (unlike commit/rebase/publish) that stays Rails-owned
    # since it can happen mid-run, independent of the terminal git worker.
    def ensure_conversation_pr!(run)
      return run.pull_request_url if run.pull_request_url.present?

      run.with_lock do
        return run.reload.pull_request_url if run.pull_request_url.present?

        root = validated_root!(run)
        checkpoint_for_conversation!(run, root)
        run.update!(conversation_pr_status: "publishing", publication_error: nil)
        git!(root, "push", "-u", "origin", run.branch_name)
        url = existing_pr_url(root, run.branch_name) || create_pr(root, run, draft: true)
        run.update!(pull_request_url: url, conversation_pr_status: "draft")
        url
      end
    rescue StandardError => error
      run.update!(conversation_pr_status: "failed", publication_error: error.message) if run.persisted?
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def publish_question!(question)
      return :unmanaged unless question.run&.managed_worktree?

      question.with_lock do
        return :published if question.github_comment_id.present?

        run = question.run
        url = ensure_conversation_pr!(run)
        root = validated_root!(run)
        body = <<~MARKDOWN
          ## Workflow question #{question.question_id}

          #{question.text}

          #{question.context.presence || "No additional context was supplied."}

          Just reply on this PR to answer and resume the run. If more than one question is open at once, reference this one explicitly with `Question #{question.question_id}: <your answer>` so it's clear which one you're answering.
        MARKDOWN
        comment = post_pr_comment!(root, url, body)
        question.update!(github_comment_id: comment.fetch("id").to_s, github_comment_url: comment["html_url"], github_published_at: Time.current, github_publication_error: nil)
        :published
      end
    rescue StandardError => error
      question.update!(github_publication_error: error.message) if question.persisted?
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def existing_pr_url(root, branch)
      output, _error, status = Open3.capture3(
        "gh", "pr", "list", "--head", branch, "--state", "open", "--json", "url", "--jq", ".[0].url",
        chdir: root.to_s
      )
      status.success? ? output.strip.presence : nil
    end

    def merged?(run)
      output, _error, status = Open3.capture3("gh", "pr", "view", run.pull_request_url, "--json", "state", chdir: run.target_root)
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

    def build_pr_body(run, root, assets: [])
      [
        "Automated workflow run: #{run.run_id}",
        "Worktree: #{run.worktree_name}",
        "Base: #{run.base_sha}",
        run_summary(run, root),
        review_assets_section(assets)
      ].compact.join("\n\n")
    end
    private_class_method :build_pr_body

    def create_pr(root, run, draft: false, assets: [])
      args = [
        "gh", "pr", "create", "--base", "main", "--head", run.branch_name,
        "--title", run.task.to_s.truncate(120), "--body", build_pr_body(run, root, assets:)
      ]
      args << "--draft" if draft
      output, error, status = Open3.capture3(*args, chdir: root.to_s)
      raise Error, "gh pr create failed: #{error.presence || output}" unless status.success?

      output.strip
    end

    def post_pr_comment!(root, url, body)
      repository, number = repository_and_number(url)
      output, error, status = Open3.capture3("gh", "api", "--method", "POST", "repos/#{repository}/issues/#{number}/comments", "-f", "body=#{body}", chdir: root.to_s)
      raise Error, "gh api comment failed: #{error.presence || output}" unless status.success?

      JSON.parse(output)
    end
    private_class_method :post_pr_comment!

    def delete_review_release!(root, run)
      tag = "workflow-evidence-#{run.run_id}"
      _output, _error, status = Open3.capture3("gh", "release", "delete", tag, "--yes", "--cleanup-tag", chdir: root.to_s)
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

    def review_assets_section(assets)
      return "## Review evidence\n\nNo review assets were selected for upload." if assets.empty?

      "## Review evidence\n\n" + assets.map { |asset| "- [#{asset[:label]}](#{asset[:url]})" }.join("\n")
    end
    private_class_method :review_assets_section

    def checkpoint_for_conversation!(run, root)
      stage_for_publication!(root)
      dirty = !git_success?(root, "diff", "--cached", "--quiet")
      message = dirty ? "Checkpoint before workflow question" : "Start workflow conversation"
      git!(root, "commit", "--allow-empty", "-m", message)
    end
    private_class_method :checkpoint_for_conversation!

    def repository_and_number(url)
      uri = URI.parse(url)
      parts = uri.path.split("/").reject(&:blank?)
      raise Error, "Invalid pull request URL: #{url}" unless parts.length >= 4 && parts[-2] == "pull"

      [ parts.first(2).join("/"), parts.last ]
    rescue URI::InvalidURIError
      raise Error, "Invalid pull request URL: #{url}"
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

    # Runtime output stays local -- used only by the mid-run question
    # checkpoint commit above, which (unlike the terminal git worker) never
    # needs to reconcile exclusion requests: it always stages every source
    # change as-is.
    def stage_for_publication!(root)
      runtime_root = relative_path(root, ArtifactStore.output_dir(root))
      git!(root, "reset", "--", runtime_root) if runtime_root.present?
      source_paths = git_status_paths(root).reject do |path|
        status_path = path.delete_suffix("/")
        runtime_root.present? && (
          status_path == runtime_root ||
          status_path.start_with?("#{runtime_root}/") ||
          runtime_root.start_with?("#{status_path}/")
        )
      end
      git!(root, "add", "--", *source_paths) if source_paths.any?
    end
    private_class_method :stage_for_publication!

    def git_status_paths(root)
      entries = git!(root, "status", "--porcelain", "-z").split("\0")
      entries.each_with_object([]) do |entry, paths|
        next if entry.blank?

        paths << entry.byteslice(3..)
        entries.shift if entry.start_with?("R", "C", " R", " C", "R ", "C ")
      end
    end
    private_class_method :git_status_paths

    def run_summary(run, root)
      ArtifactStore.read(root, run.run_id, "run-summary.md").presence
    rescue Errno::ENOENT
      nil
    end
    private_class_method :run_summary

    def relative_path(root, path)
      expanded_root = root.expand_path.to_s
      expanded_path = Pathname(path).expand_path.to_s
      return unless expanded_path.start_with?("#{expanded_root}#{File::SEPARATOR}")

      expanded_path.delete_prefix("#{expanded_root}#{File::SEPARATOR}")
    end
    private_class_method :relative_path

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?

      raise Error, "git #{args.join(' ')} failed: #{error.presence || output}"
    end

    def git_success?(root, *args)
      _output, _error, status = Open3.capture3("git", "-C", root.to_s, *args)
      status.success?
    end
    private_class_method :git_success?

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
  end
end
