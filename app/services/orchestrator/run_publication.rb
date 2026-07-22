require "open3"

module Orchestrator
  module RunPublication
    class Error < StandardError; end
    module_function

    # The committer worker deliberately requests this action after reviewing
    # the whole worktree. Rails performs the Git metadata write because the
    # worker sandbox must never receive broad access to .git internals.
    def commit_all!(run)
      return :unmanaged if run.worktree_name.blank?
      return :committed if run.publication_status == "committed"
      return :no_changes if run.publication_status == "no_changes"

      run.with_lock do
        root = validated_root!(run)
        run.update!(publication_status: "committing", publication_error: nil, publication_started_at: Time.current)
        if git!(root, "status", "--porcelain").empty?
          run.update!(publication_status: "no_changes", publication_completed_at: Time.current)
          return :no_changes
        end

        git!(root, "add", "-A")
        evidence_paths(run, root).each { |path| git!(root, "add", "-f", "--", path) }
        git!(root, "commit", "-m", run.task.to_s.truncate(72))
        run.update!(publication_status: "committed", publication_completed_at: Time.current)
        :committed
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def publish!(run)
      return :unmanaged if run.worktree_name.blank?
      return :published if run.publication_status == "published"
      return :no_changes if run.publication_status == "no_changes"

      run.with_lock do
        return :published if run.reload.publication_status == "published"

        root = validated_root!(run)
        raise Error, "Run changes have not been committed" unless run.publication_status == "committed"

        run.update!(publication_status: "publishing", publication_error: nil)
        git!(root, "push", "-u", "origin", run.branch_name)
        url = existing_pr_url(root, run.branch_name) || create_pr(root, run)
        run.update!(publication_status: "awaiting_approval", pull_request_url: url, publication_completed_at: Time.current)
        :published
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def existing_pr_url(root, branch)
      output, _error, status = Open3.capture3("gh", "pr", "view", branch, "--json", "url", "--jq", ".url", chdir: root.to_s)
      status.success? ? output.strip.presence : nil
    end

    def approved?(run)
      output, _error, status = Open3.capture3("gh", "pr", "view", run.pull_request_url, "--json", "state,reviewDecision", chdir: run.target_root)
      return false unless status.success?

      details = JSON.parse(output)
      details["state"] == "OPEN" && details["reviewDecision"] == "APPROVED"
    rescue JSON::ParserError
      false
    end

    def remove_evidence!(run)
      run.with_lock do
        root = validated_root!(run)
        return :already_cleaned if run.publication_status == "cleanup_pushed"

        evidence_paths(run, root).each { |path| git!(root, "rm", "-r", "--ignore-unmatch", "--", path) }
        if git!(root, "status", "--porcelain").empty?
          run.update!(publication_status: "cleanup_pushed", publication_error: nil)
          return :nothing_to_remove
        end

        git!(root, "commit", "-m", "Remove run evidence before merge")
        git!(root, "push", "origin", run.branch_name)
        run.update!(publication_status: "cleanup_pushed", publication_error: nil)
        :cleaned
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def merge_and_cleanup!(run)
      run.with_lock do
        root = validated_root!(run)
        raise Error, "PR evidence cleanup has not completed" unless run.publication_status == "cleanup_pushed"

        _output, _error, status = Open3.capture3("gh", "pr", "merge", run.pull_request_url, "--squash", "--delete-branch", chdir: root.to_s)
        return :not_ready unless status.success?

        source_root = Pathname(run.source_root)
        git!(source_root, "worktree", "remove", root.to_s)
        git!(source_root, "worktree", "prune")
        run.update!(publication_status: "merged", publication_error: nil)
        :merged
      end
    rescue StandardError => error
      record_failure!(run, error)
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def create_pr(root, run)
      body = "Automated workflow run: #{run.run_id}\n\nWorktree: #{run.worktree_name}\nBase: #{run.base_sha}\n"
      output, error, status = Open3.capture3("gh", "pr", "create", "--base", "main", "--head", run.branch_name, "--title", run.task.to_s.truncate(120), "--body", body, chdir: root.to_s)
      raise Error, "gh pr create failed: #{error.presence || output}" unless status.success?

      output.strip
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
    private_class_method :validated_root!

    def record_failure!(run, error)
      run.update!(publication_status: "failed", publication_error: error.message) if run.persisted?
    end
    private_class_method :record_failure!

    def evidence_paths(run, root)
      paths = []
      artifact_dir = File.join(ArtifactStore.output_dir(root), ArtifactStore.sanitize_run_id(run.run_id))
      paths << relative_path(root, artifact_dir) if Dir.exist?(artifact_dir)
      run.workers.find_each do |worker|
        [ worker.prompt_path, worker.log_path, worker.last_message_path, worker.exit_status_path, worker.env_path, worker.mcp_config_path ].compact.each do |path|
          paths << relative_path(root, path) if File.exist?(path)
        end
      end
      paths.compact.uniq
    end
    private_class_method :evidence_paths

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
  end
end
