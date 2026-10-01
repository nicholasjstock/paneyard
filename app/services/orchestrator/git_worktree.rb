module Orchestrator
  # A run's worktree: which branch it gets and starts from, and recording it
  # once herdr has made it. herdr decides where it goes and opens it as the
  # run's herdr workspace in the same call (Runner::Local#provision_worktree),
  # so provisioning also gives the session its workspace and agent pane.
  module GitWorktree
    module_function

    # Records the worktree on the run and the herdr workspace on the session,
    # straight away, so that a launch failing after this still leaves a
    # workspace to close and a worktree the janitor knows is the run's.
    def provision!(run, session:)
      name = run.worktree_name.presence || name_for(run)
      current = run.target_root if run.worktree_name.present? && run.branch_name.present? && run.source_root.present?
      result = Runner.for(run.workspace).provision_worktree(
        repository_path: run.workspace.repository_path, branch: run.branch_name.presence || "paneyard/#{name}",
        base_branch: run.base_branch, label: name, current_target_root: current
      )

      session.update!(
        herdr_workspace_id: result.fetch("workspace_id"), herdr_tab_id: result.fetch("tab_id"),
        herdr_pane_id: result.fetch("pane_id")
      )
      return run if result.fetch("reused")

      run.update!(
        worktree_name: name, source_root: result.fetch("repository_path"), branch_name: result.fetch("branch"),
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
