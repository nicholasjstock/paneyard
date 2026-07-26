require "open3"
require "uri"

module Orchestrator
  module RunPublication
    class Error < StandardError; end
    module_function

    # The committer worker deliberately requests this action after reviewing
    # the whole worktree. Rails performs the Git metadata write because the
    # worker sandbox must never receive broad access to .git internals.
    # exclude_paths is the committer's own reconciled decision about which
    # pending GitChangeRequests to honor -- see request_git_change! and
    # resolve_git_change_requests!; Rails applies exactly that list and
    # nothing more.
    def commit_all!(run, exclude_paths: [])
      return :unmanaged if run.worktree_name.blank?
      return :committed if run.publication_status == "committed"
      return :no_changes if run.publication_status == "no_changes"

      run.with_lock do
        root = validated_root!(run)
        run.update!(publication_status: "committing", publication_error: nil, publication_started_at: Time.current)
        stage_for_publication!(run, root, exclude_paths:)
        resolve_git_change_requests!(run, exclude_paths)
        if git_success?(root, "diff", "--cached", "--quiet")
          run.update!(publication_status: "no_changes", publication_completed_at: Time.current)
          return :no_changes
        end

        git!(root, "commit", "-m", run.task.to_s.truncate(72))
        run.update!(publication_status: "committed", publication_completed_at: Time.current)
        :committed
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    # A worker can request an untracked pending path, or a path that is
    # already tracked despite matching .gitignore (the latter is the common
    # "old test log committed by mistake" case). This is only a request: the
    # terminal committer reviews it before Rails changes the index. The
    # unique index on (run_id, path) means re-requesting the same path is a
    # no-op rather than a way to pile up duplicate requests.
    MAX_PENDING_GIT_CHANGE_REQUESTS = 20

    def request_git_change!(run:, requested_by_worker_id:, path:, reason:)
      root = validated_root!(run)
      unless requestable_git_change_path?(root, path)
        raise Error, "Path is not part of this run's pending changes or a tracked ignored artifact: #{path}"
      end

      if run.git_change_requests.pending.count >= MAX_PENDING_GIT_CHANGE_REQUESTS
        raise Error, "Too many pending git change requests for this run (max #{MAX_PENDING_GIT_CHANGE_REQUESTS})"
      end

      run.git_change_requests.create!(requested_by_worker_id:, path:, reason:, status: "requested")
    end

    def requestable_git_change_path?(root, path)
      return true if git_status_paths(root).include?(path)

      git_success?(root, "ls-files", "--error-unmatch", "--", path) &&
        git_success?(root, "check-ignore", "-q", "--", path)
    end
    private_class_method :requestable_git_change_path?

    def resolve_git_change_requests!(run, exclude_paths)
      run.git_change_requests.pending.find_each do |request|
        request.update!(status: exclude_paths.include?(request.path) ? "applied" : "dismissed")
      end
    end
    private_class_method :resolve_git_change_requests!

    def publish!(run)
      return :unmanaged if run.worktree_name.blank?
      return :published if run.publication_status == "published" && run.conversation_pr_status == "ready"
      return :published if run.publication_status == "awaiting_approval" && run.pull_request_url.present? && run.conversation_pr_status == "ready"
      return :no_changes if run.publication_status == "no_changes" && run.pull_request_url.blank?
      return :merge_conflict if run.publication_status == "merge_conflict"

      run.with_lock do
        return :published if run.reload.publication_status == "published"

        root = validated_root!(run)
        unless run.publication_status.in?(%w[committed no_changes])
          raise Error, "Run changes have not been committed"
        end

        run.update!(publication_status: "publishing", publication_error: nil)
        return :merge_conflict if rebase_onto_main!(run, root:) == :conflicted

        git!(root, "push", "--force-with-lease", "-u", "origin", run.branch_name)
        assets = publish_review_assets!(root, run)
        url = existing_pr_url(root, run.branch_name)
        if url
          # conversation_pr_status only reads "draft" for a PR that
          # ensure_conversation_pr! opened early (e.g. for a blocking
          # question) and that has never been finalized since -- its body
          # is still the placeholder create_pr wrote with no run summary
          # and no review assets, because that's the only time this branch
          # runs. Once flipped to "ready" below, a later publish! for the
          # same run (e.g. the operator replies on the PR asking for a
          # rerun, and the run does more work and finishes again) posts the
          # fresh summary as a new comment instead of overwriting the body:
          # the body is the run's one settled description, while a rerun's
          # outcome is new information that belongs in the PR's timeline
          # alongside the comment that triggered it, not silently replacing
          # what was there.
          if run.conversation_pr_status == "draft"
            update_pr_body!(root, url, build_pr_body(run, root, assets:))
            ready_pr!(root, url)
          else
            post_rerun_summary_comment!(root, url, run, assets:)
          end
        else
          url = create_pr(root, run, assets:)
        end
        run.update!(publication_status: "awaiting_approval", pull_request_url: url, conversation_pr_status: "ready", publication_completed_at: Time.current)
        :published
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    # Rails, rather than a sandboxed worker, owns Git history operations.
    # A clean rebase makes the PR genuinely reviewable; a conflicted rebase
    # leaves only source files for a normal implementation worker to repair.
    def rebase_onto_main!(run, root: nil)
      root ||= validated_root!(run)
      git!(root, "fetch", "origin", "main")
      _output, error, status = Open3.capture3("git", "-C", root.to_s, "rebase", "origin/main")
      return :rebased if status.success?

      if rebase_in_progress?(root)
        run.update!(publication_status: "merge_conflict", publication_error: error.presence || "Rebase onto main has conflicts")
        return :conflicted
      end

      raise Error, "git rebase origin/main failed: #{error}"
    end

    def continue_rebase_onto_main!(run, paths:)
      root = validated_root!(run)
      raise Error, "No merge-conflict rebase is in progress" unless rebase_in_progress?(root)
      raise Error, "Merge-conflict worker left conflict markers behind" if conflict_markers?(root, paths)

      git!(root, "add", "--", *paths)
      output, error, status = Open3.capture3({ "GIT_EDITOR" => "true" }, "git", "-C", root.to_s, "rebase", "--continue")
      return :rebased if status.success?

      if rebase_in_progress?(root)
        run.update!(publication_status: "merge_conflict", publication_error: error.presence || output.presence || "Rebase has further conflicts")
        return :conflicted
      end

      raise Error, "git rebase --continue failed: #{error.presence || output}"
    end

    def merge_conflict_paths(run)
      root = validated_root!(run)
      git!(root, "diff", "--name-only", "--diff-filter=U").lines.map(&:strip).reject(&:blank?)
    end

    def prepare_retry!(run)
      root = validated_root!(run)
      if git_success?(root, "diff", "--quiet", run.base_sha, "HEAD")
        run.update!(publication_status: "queued", publication_error: nil)
        commit_all!(run)
      else
        run.update!(publication_status: "committed", publication_error: nil)
        :committed
      end
    end

    # A question is sufficient reason to establish the run's shared GitHub
    # conversation. A clean branch receives an empty commit because GitHub
    # cannot open a PR for a branch identical to its base.
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

    def update_pr_body!(root, url, body)
      _output, error, status = Open3.capture3("gh", "pr", "edit", url, "--body", body, chdir: root.to_s)
      raise Error, "gh pr edit failed: #{error}" unless status.success?
    end
    private_class_method :update_pr_body!

    def post_pr_comment!(root, url, body)
      repository, number = repository_and_number(url)
      output, error, status = Open3.capture3("gh", "api", "--method", "POST", "repos/#{repository}/issues/#{number}/comments", "-f", "body=#{body}", chdir: root.to_s)
      raise Error, "gh api comment failed: #{error.presence || output}" unless status.success?

      JSON.parse(output)
    end
    private_class_method :post_pr_comment!

    # A rerun's outcome is new information appended to the PR's timeline,
    # not a replacement for the body's settled description -- see the
    # comment at this method's call site in publish!.
    def post_rerun_summary_comment!(root, url, run, assets: [])
      body = <<~MARKDOWN
        ## Run finished again

        #{run_summary(run, root) || "No summary was recorded for this pass."}

        #{review_assets_section(assets)}
      MARKDOWN
      post_pr_comment!(root, url, body)
    end
    private_class_method :post_rerun_summary_comment!

    def publish_review_assets!(root, run)
      return [] if run.review_assets.empty?

      tag = "workflow-evidence-#{run.run_id}"
      unless release_exists?(root, tag)
        _output, error, status = Open3.capture3("gh", "release", "create", tag, "--draft", "--target", run.branch_name, "--title", "Workflow evidence #{run.run_id}", "--notes", "Review evidence for #{run.run_id}.", chdir: root.to_s)
        raise Error, "gh release create failed: #{error}" unless status.success?
      end

      output, error, status = Open3.capture3("gh", "release", "view", tag, "--json", "assets", chdir: root.to_s)
      raise Error, "gh release view failed: #{error}" unless status.success?
      existing_asset_names = JSON.parse(output).fetch("assets").map { |entry| entry.fetch("name") }

      run.review_assets.find_each do |asset|
        path = review_asset_path!(root, asset.workspace_path)

        unless asset.github_url.present? || existing_asset_names.include?(File.basename(asset.workspace_path))
          _output, error, status = Open3.capture3("gh", "release", "upload", tag, "#{path}##{asset.label}", chdir: root.to_s)
          raise Error, "gh release upload failed: #{error}" unless status.success?
        end
      end

      output, error, status = Open3.capture3("gh", "release", "view", tag, "--json", "url,assets", chdir: root.to_s)
      raise Error, "gh release view failed: #{error}" unless status.success?

      details = JSON.parse(output)
      run.review_assets.find_each do |asset|
        url = details.fetch("assets").find { |entry| entry["name"] == File.basename(asset.workspace_path) }&.fetch("url", nil)
        asset.update!(github_url: url)
      end
      run.review_assets.reload.map { |asset| { label: asset.label, url: asset.github_url } }
    end
    private_class_method :publish_review_assets!

    def release_exists?(root, tag)
      _output, _error, status = Open3.capture3("gh", "release", "view", tag, chdir: root.to_s)
      status.success?
    end
    private_class_method :release_exists?

    def review_asset_path!(root, workspace_path)
      path = Pathname(root).join(workspace_path).cleanpath
      unless path.to_s.start_with?("#{Pathname(root).expand_path}/") && path.file?
        raise Error, "Selected review asset is missing: #{workspace_path}"
      end

      path
    end
    private_class_method :review_asset_path!

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

    def ready_pr!(root, url)
      _output, error, status = Open3.capture3("gh", "pr", "ready", url, chdir: root.to_s)
      raise Error, "gh pr ready failed: #{error}" unless status.success?
    end
    private_class_method :ready_pr!

    def checkpoint_for_conversation!(run, root)
      stage_for_publication!(run, root)
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

    # Runtime output stays local. The committer's concise run summary becomes
    # the PR body; raw logs, prompts, environment snapshots, MCP configs, and
    # command output must never enter Git history.
    def stage_for_publication!(run, root, exclude_paths: [])
      runtime_root = relative_path(root, ArtifactStore.output_dir(root))
      git!(root, "reset", "--", runtime_root) if runtime_root.present?
      exclude_paths.each do |path|
        # An approved removal can name a stale path that is still in the
        # index but absent from the working tree. `git add` cannot remove
        # that path, so the Rails-owned finalizer performs the index update
        # before staging the remaining source changes.
        git!(root, "rm", "--cached", "--ignore-unmatch", "--", path)
      end
      source_paths = git_status_paths(root).reject do |path|
        status_path = path.delete_suffix("/")
        exclude_paths.include?(status_path) ||
          (runtime_root.present? && (
            status_path == runtime_root ||
            status_path.start_with?("#{runtime_root}/") ||
            runtime_root.start_with?("#{status_path}/")
          ))
      end
      git!(root, "add", "--", *source_paths) if source_paths.any?
    end
    private_class_method :stage_for_publication!

    def rebase_in_progress?(root)
      git_dir = git!(root, "rev-parse", "--git-dir").strip
      git_dir = Pathname(root).join(git_dir) unless Pathname(git_dir).absolute?
      File.directory?(Pathname(git_dir).join("rebase-merge")) || File.directory?(Pathname(git_dir).join("rebase-apply"))
    end
    private_class_method :rebase_in_progress?

    def conflict_markers?(root, paths)
      return false if paths.empty?

      _output, _error, status = Open3.capture3(
        "git", "-C", root.to_s, "grep", "-nE", "^(<<<<<<<|=======|>>>>>>>)", "--", *paths
      )
      status.success?
    end
    private_class_method :conflict_markers?

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
  end
end
