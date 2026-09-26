require "open3"

module Orchestrator
  module GitWorktree
    class Error < StandardError; end
    module_function

    def provision!(run)
      source_root = Pathname(run.workspace.source_root)
      name = run.worktree_name.presence || name_for(run)
      branch = "workflow/#{name}"
      worktree = source_root.parent.join(name)
      return run if provisioned?(run, worktree)

      validate_source!(source_root)
      raise Error, "Worktree path already exists: #{worktree}" if worktree.exist?

      base_sha = git!(source_root, "rev-parse", "HEAD").strip
      git!(source_root, "worktree", "add", "-b", branch, worktree.to_s, base_sha)
      run.update!(
        worktree_name: name, source_root: source_root.to_s, branch_name: branch,
        base_sha: base_sha, target_root: worktree.to_s
      )
      run
    end

    # Checks a run's existing branch back out where its worktree was, after
    # WorktreeJanitor.release! reclaimed it on close, so a reopened session
    # picks up exactly where the branch left off.
    def restore!(run)
      worktree = Pathname(run.target_root.to_s)
      return run if worktree.directory?
      raise Error, "run #{run.run_id} has no branch to restore" if run.branch_name.blank? || run.source_root.blank?

      git!(run.source_root, "worktree", "prune")
      git!(run.source_root, "worktree", "add", worktree.to_s, run.branch_name)
      run
    end

    def provisioned?(run, worktree)
      return false unless run.worktree_name.present? && run.branch_name.present? && run.source_root.present?
      return false unless Pathname(run.target_root).expand_path == worktree.expand_path

      worktree.directory?
    end

    def validate_source!(source_root)
      raise Error, "Source checkout does not exist: #{source_root}" unless source_root.directory?
      raise Error, "Source checkout must be named main: #{source_root}" unless source_root.basename.to_s == "main"
      raise Error, "Source checkout is not a Git repository: #{source_root}" unless git_success?(source_root, "rev-parse", "--is-inside-work-tree")
      raise Error, "Source checkout must be on main" unless git!(source_root, "branch", "--show-current").strip == "main"
      raise Error, "Source checkout has no origin remote: #{source_root}" unless git_success?(source_root, "remote", "get-url", "origin")
    end

    def name_for(run)
      slug = run.task.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-").first(48)
      slug = "task" if slug.blank?
      suffix = run.run_id.to_s.split("-").last.to_s.gsub(/[^a-z0-9]/i, "").last(8)
      suffix = SecureRandom.hex(3) if suffix.blank?
      "#{slug}-#{suffix}"
    end

    def git!(root, *args)
      output, error, status = Open3.capture3("git", "-C", root.to_s, *args)
      return output if status.success?
      raise Error, "git #{args.join(' ')} failed: #{error.presence || output}"
    end

    def git_success?(root, *args)
      _output, _error, status = Open3.capture3("git", "-C", root.to_s, *args)
      status.success?
    end
  end
end
