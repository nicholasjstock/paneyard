require "open3"

module Orchestrator
  module RunPublication
    class Error < StandardError; end
    module_function

    def publish!(run)
      return :unmanaged if run.worktree_name.blank?
      return :published if run.publication_status == "published"

      run.with_lock do
        return :published if run.reload.publication_status == "published"
        run.update!(publication_status: "publishing", publication_error: nil, publication_started_at: Time.current)
        root = Pathname(run.target_root)
        raise Error, "Run worktree does not exist: #{root}" unless root.directory?
        raise Error, "Run has no publication branch" if run.branch_name.blank?
        if run.source_root.present? && root.expand_path == Pathname(run.source_root).expand_path
          raise Error, "Refusing to publish directly from the source checkout"
        end
        if git!(root, "status", "--porcelain").empty?
          run.update!(publication_status: "no_changes", publication_completed_at: Time.current)
          return :no_changes
        end
        git!(root, "add", "-A")
        git!(root, "commit", "-m", run.task.to_s.truncate(72))
        git!(root, "push", "-u", "origin", run.branch_name)
        url = existing_pr_url(root, run.branch_name) || create_pr(root, run)
        run.update!(publication_status: "published", pull_request_url: url, publication_completed_at: Time.current)
        :published
      end
    rescue StandardError => error
      run.update!(publication_status: "failed", publication_error: error.message) if run.persisted?
      raise error if error.is_a?(Error)

      raise Error, error.message
    end

    def existing_pr_url(root, branch)
      output, _error, status = Open3.capture3("gh", "pr", "view", branch, "--json", "url", "--jq", ".url", chdir: root.to_s)
      status.success? ? output.strip.presence : nil
    end

    def create_pr(root, run)
      body = "Automated workflow run: #{run.run_id}\n\nWorktree: #{run.worktree_name}\nBase: #{run.base_sha}\n"
      output, error, status = Open3.capture3("gh", "pr", "create", "--base", "main", "--head", run.branch_name, "--title", run.task.to_s.truncate(120), "--body", body, chdir: root.to_s)
      raise Error, "gh pr create failed: #{error.presence || output}" unless status.success?
      output.strip
    end

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?
      raise Error, "git #{args.join(' ')} failed: #{error.presence || output}"
    end
  end
end
