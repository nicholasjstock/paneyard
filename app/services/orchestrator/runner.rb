module Orchestrator
  # The seam between the orchestrator and the machine a run actually happens
  # on.
  #
  # The orchestrator (everything else in this app: the database, the UI, the
  # MCP endpoints, the queue and concurrency, run and session state)
  # decides which job runs, where, and what becomes of it. A runner is what
  # carries that out on the machine that hosts herdr, the agent CLIs, the git
  # checkouts and their worktrees: it opens and drives sessions, provisions and
  # reclaims worktrees, stores launch attachments, and reports what CLIs and
  # models that machine has.
  #
  # Everything that touches that machine -- the herdr socket, git, files under
  # a workspace's root, process signals, the runner's own environment and
  # CLI config -- lives under Orchestrator::Runner and is reached only through
  # a runner object (Runner.for). spec/boundary_spec.rb fails if anything
  # outside it reaches for the machine directly.
  #
  # What crosses the boundary is plain data: strings, integers, booleans, and
  # hashes and arrays of them, never an Active Record object. Paths (a
  # workspace's repository_path, a run's target_root, a session's prompt_path)
  # are the runner's, and the orchestrator only stores and hands them back.
  #
  # Each run belongs to a runner in the registry (RegisteredRunner, the
  # runners table), and Runner.for(run) is that runner's object. The local one
  # is Runner::Local, in this process and on this machine. A different
  # implementation with the same public methods (see Runner::Local) takes its
  # place for a remote runner, Runner::Remote, over HTTP to that machine's
  # runner-only process (bin/runner), without the orchestrator changing
  # (docs/multi-runner-plan.md).
  module Runner
    module_function

    # Anything the runner could not do. Callers outside the runner rescue this
    # (or Unreachable), never an implementation's own errors.
    class Error < StandardError; end

    # The runner, or the herdr behind it, never answered, so nothing is known
    # about the thing that was asked about. Distinct from Error, which is an
    # answer ("no such pane"): RunSessionRunner.refresh! must not treat a blip
    # as proof that a session is gone.
    class Unreachable < Error; end

    # A session's agent never came up (see Runner::SessionLauncher).
    class LaunchError < Error; end

    # The runner object for a run's runner, which is where everything about
    # that run happens on the machine. Takes:
    #
    #   a Run (or RunSession)  its runner (Run#runner)
    #   a RegisteredRunner     that runner
    #   a Workspace, or nil    the local runner: callers with no run, such as
    #                          the lobby and workspace registration, are on
    #                          this machine for now
    #
    # This is the one place a runner record becomes an implementation, and
    # the only orchestrator data the runner module sees: the object returned
    # is handed plain data only. The local record is Runner::Local; a remote
    # one is a Runner::Remote for its url (docs/multi-runner-plan.md).
    def for(subject)
      resolve(registered(subject))
    end

    def resolve(record)
      return local if record.nil? || record.local?

      Remote.new(name: record.name, url: record.url)
    end

    def registered(subject)
      case subject
      when nil, ::Workspace then nil
      when ::Run then subject.runner
      when ::RunSession then subject.run&.runner
      when ::RegisteredRunner then subject
      else raise ArgumentError, "no runner for #{subject.class}"
      end
    end

    def local
      @local ||= Local.new
    end
  end
end
