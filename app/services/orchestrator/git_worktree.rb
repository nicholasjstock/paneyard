module Orchestrator
  # A run's worktree: which one it gets, and recording it once the runner has
  # made it (Runner::Local#provision_worktree does the git).
  module GitWorktree
    module_function

    def provision!(run)
      name = run.worktree_name.presence || name_for(run)
      current = run.target_root if run.worktree_name.present? && run.branch_name.present? && run.source_root.present?
      result = Runner.for(run.workspace).provision_worktree(
        source_root: run.workspace.source_root, name:, current_target_root: current
      )
      return run if result.fetch("reused")

      run.update!(
        worktree_name: name, source_root: result.fetch("source_root"), branch_name: result.fetch("branch"),
        base_sha: result.fetch("base_sha"), target_root: result.fetch("target_root")
      )
      run
    end

    def name_for(run)
      slug = run.task.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-").first(48)
      slug = "task" if slug.blank?
      suffix = run.run_id.to_s.split("-").last.to_s.gsub(/[^a-z0-9]/i, "").last(8)
      suffix = SecureRandom.hex(3) if suffix.blank?
      "#{slug}-#{suffix}"
    end
  end
end
