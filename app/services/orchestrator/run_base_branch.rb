module Orchestrator
  # The branch a run starts from and merges back into: the one the caller
  # named, else the workspace's default. Checked against the repository before
  # the run is queued (the runner's git, the same rule provisioning enforces),
  # so a typo is an error now rather than a failed launch once a slot frees.
  module RunBaseBranch
    module_function

    def for(workspace, requested)
      requested.to_s.strip.presence || workspace.default_base_branch
    end

    # nil when runs can start from `branch`, else why not and how to fix it.
    # Checked in the checkout on `runner`, the machine the run is queued on
    # (nil: the local one), since each machine has its own copy of the branch.
    # A runner with no checkout yet is not asked: it clones one at launch
    # (WorkspaceCheckout), which is when provisioning checks the branch there.
    def problem(workspace, branch, runner: nil)
      runner ||= RegisteredRunner.local
      repository_path = workspace.checkout_path(runner)
      return unless repository_path

      found = Runner.for(runner).base_branch_problem(repository_path:, branch:)
      found && "Base branch `#{branch}`: #{found.fetch('message')}"
    rescue Runner::Error => error
      "Could not check base branch `#{branch}`: #{error.message}"
    end
  end
end
