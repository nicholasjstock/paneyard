require "open3"

module Orchestrator
  module GitWorktree
    class Error < StandardError; end
    module_function

    def provision!(run)
      return run if run.worktree_name.present? && Pathname(run.target_root).directory?

      source_root = Pathname(run.workspace.root_path).expand_path
      validate_source!(source_root)
      name = run.worktree_name.presence || name_for(run)
      branch = "workflow/#{name}"
      worktree = source_root.parent.join(name)
      raise Error, "Worktree path already exists: #{worktree}" if worktree.exist?

      git!(source_root, "fetch", "origin", "main")
      base_sha = git!(source_root, "rev-parse", "origin/main").strip
      git!(source_root, "worktree", "add", "-b", branch, worktree.to_s, base_sha)
      run.update!(
        worktree_name: name, source_root: source_root.to_s, branch_name: branch,
        base_sha: base_sha, target_root: worktree.to_s
      )
      run
    end

    def validate_source!(source_root)
      raise Error, "Source checkout does not exist: #{source_root}" unless source_root.directory?
      raise Error, "Source checkout must be named main: #{source_root}" unless source_root.basename.to_s == "main"
      raise Error, "Source checkout is not a Git repository: #{source_root}" unless git_success?(source_root, "rev-parse", "--is-inside-work-tree")
      raise Error, "Source checkout has uncommitted changes: #{source_root}" unless git!(source_root, "status", "--porcelain").empty?
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
