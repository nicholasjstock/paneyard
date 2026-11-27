module Orchestrator
  # The machine a run is queued on (queue_run's `runner`, Run#runner): the
  # runner the caller named, else a sensible default. Any runner will do that
  # has a checkout of the workspace's repository, or a projects directory to
  # clone one into when the run launches (WorkspaceCheckout); the local
  # runner is no different, except that it always has a projects directory.
  #
  # The default, when no runner is named, prefers a runner that already has a
  # checkout:
  #   1. the calling run's own runner: a session queuing follow-up work
  #      defaults to its own machine;
  #   2. else the local runner, when it has a checkout;
  #   3. else the first runner (by name) that has one, e.g. the remote runner
  #      a remote-only workspace was registered on;
  #   4. else the local runner, which clones it.
  # With only the local runner registered, that is always the local runner.
  module RunRunner
    class Invalid < ArgumentError; end

    module_function

    def choose!(workspace, requested, caller_run: nil)
      name = requested.to_s.strip.presence
      if name
        candidates = candidates(workspace)
        return candidates.find { |runner| runner.name == name } || raise(Invalid, problem(workspace, name, candidates))
      end

      local = RegisteredRunner.local
      checked_out = workspace.checked_out_runners
      own = caller_run&.runner
      return own if own && checked_out.include?(own)
      return local if checked_out.include?(local)

      checked_out.first || local
    end

    # The registered runner called `name`, or the local one for a blank name.
    # For tools that take a runner to act on (register_workspace,
    # create_workspace).
    def named!(name)
      name = name.to_s.strip
      return RegisteredRunner.local if name.empty?

      RegisteredRunner.find_by(name:) ||
        raise(Invalid, "there is no runner named #{name.inspect}. Runners: #{RegisteredRunner.order(:name).pluck(:name).join(', ')} (list_runners).")
    end

    # The runners a run of the workspace can be queued on, local first, then
    # by name: those with a checkout of it, and those that can clone one.
    def candidates(workspace)
      local = RegisteredRunner.local
      runners = [ local, *RegisteredRunner.where.not(id: local.id).order(:name) ]
      runners.select { |runner| WorkspaceCheckout.available?(workspace, runner) }
    end

    def problem(workspace, name, candidates)
      valid = "Runners that can run #{workspace.name.inspect}: #{candidates.map(&:name).join(', ')}."
      if RegisteredRunner.exists?(name:)
        "runner #{name.inspect} has no checkout of workspace #{workspace.name.inspect} and no projects directory to " \
          "clone it into (it sends one when it registers). #{valid}"
      else
        "there is no runner named #{name.inspect}. #{valid}"
      end
    end
    private_class_method :problem
  end
end
