module Orchestrator
  # The machine a run is queued on (queue_run's `runner`, Run#runner): the
  # runner the caller named, else a sensible default. Either way it must have
  # a checkout of the workspace's repository (Workspace#repository_path_for),
  # since that is where the run's worktree is made.
  #
  # The default, when no runner is named:
  #   1. the calling run's own runner, when it has a checkout here: a session
  #      queuing follow-up work defaults to its own machine;
  #   2. else the workspace's only runner, when it is checked out on just one;
  #   3. else the local runner.
  # With only the local runner registered, that is always the local runner.
  module RunRunner
    class Invalid < ArgumentError; end

    module_function

    def choose!(workspace, requested, caller_run: nil)
      candidates = candidates(workspace)
      name = requested.to_s.strip.presence
      if name
        return candidates.find { |runner| runner.name == name } || raise(Invalid, problem(workspace, name, candidates))
      end

      own = caller_run&.runner
      return own if own && candidates.include?(own)
      return candidates.sole if candidates.one?

      RegisteredRunner.local
    end

    # The runners with a checkout of the workspace, local first. The local
    # runner always has one: its checkout is workspaces.repository_path.
    def candidates(workspace)
      local = RegisteredRunner.local
      others = RegisteredRunner.where(id: workspace.checkouts.select(:runner_id)).where.not(id: local.id).order(:name)
      [ local, *others ]
    end

    def problem(workspace, name, candidates)
      valid = "Runners with a checkout of #{workspace.name.inspect}: #{candidates.map(&:name).join(', ')}."
      if RegisteredRunner.exists?(name:)
        "runner #{name.inspect} has no checkout of workspace #{workspace.name.inspect}. #{valid}"
      else
        "there is no runner named #{name.inspect}. #{valid}"
      end
    end
    private_class_method :problem
  end
end
