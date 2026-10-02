module Orchestrator
  # The seam between the orchestrator and the machine a run actually happens
  # on.
  #
  # The orchestrator (everything else in this app: the database, the UI, the
  # MCP endpoints, Telegram, the queue and concurrency, run and session state)
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
  # Today there is one runner, Runner::Local, in this process and on this
  # machine. A different implementation with the same public methods (see
  # Runner::Local) can later take its place, per workspace, without the
  # orchestrator changing.
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

    # The runner a workspace's runs happen on. There is one for now, so the
    # workspace is not consulted yet; it is taken so that a workspace can
    # later name its own runner without any caller changing.
    def for(_workspace)
      local
    end

    def local
      @local ||= Local.new
    end
  end
end
