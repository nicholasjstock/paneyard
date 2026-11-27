require "ipaddr"
require "open3"
require "uri"

module Orchestrator
  # The in-app side of a sandbox instance (bin/sandbox, bin/preflight; see
  # PaneyardSandbox): an isolated copy of this app booted from a worktree to
  # exercise a change before it is merged. When PANEYARD_SANDBOX=1 everything
  # that would reach outside that copy is refused here, whatever its database
  # happens to contain -- bin/preflight boots against a copy of production's,
  # full of real workspace paths and real session pids:
  #
  #   - herdr: only the sandbox's fake herdr socket, never the operator's;
  #   - git worktrees: provisioning and removal only for repositories under the
  #     sandbox root (herdr picks where the worktree itself goes: the fake herdr
  #     beside the repository, so inside the root too);
  #   - processes: a session pid is only signalled if it is a fake agent;
  #   - CLI transcripts: copied only for a worktree under the sandbox root,
  #     and a moved run's written into a CLI's config only when that config
  #     is under the root too (Runner::Transcripts.restore);
  #   - moving a run (Runner::RunTransfer): only repositories under the root,
  #     and `git fetch origin` only from an origin inside it;
  #   - cloning a workspace onto a runner (Runner::Repositories
  #     .ensure_checkout): only into a path inside the root, and only from an
  #     origin inside it;
  #   - GitHub: never; a sandbox cannot start a new project (create_workspace),
  #     which would make a real GitHub repository;
  #   - remote runners: only the sandbox's own runner-only process, a loopback
  #     url it was started with (PANEYARD_SANDBOX_RUNNER_URLS), never a
  #     runner a copied database registered on another machine;
  #
  # Herdr can be opted back in for an operator who wants to see the real
  # thing (`bin/sandbox start --real-herdr`), never by
  # bin/preflight, whose database may be a production copy:
  #
  #   - PANEYARD_SANDBOX_REAL_HERDR=1: runs open real sessions (the real CLI,
  #     real model usage) in the operator's own herdr, labelled [sandbox];
  #     signals are then allowed to pids this sandbox's own sessions recorded.
  module Sandbox
    module_function

    class Violation < StandardError; end

    LABEL_PREFIX = "[sandbox] ".freeze

    def enabled?
      PaneyardSandbox.enabled?
    end

    def real_herdr?
      enabled? && ENV["PANEYARD_SANDBOX_REAL_HERDR"] == "1"
    end

    # What a sandbox shows in the operator's herdr (workspace names,
    # notifications) is marked, so it is never mistaken for a production run.
    def label(text)
      return text unless enabled?
      return text if text.to_s.start_with?(LABEL_PREFIX)

      "#{LABEL_PREFIX}#{text}"
    end

    def root
      PaneyardSandbox.root
    end

    def herdr_socket_path
      PaneyardSandbox.herdr_socket_path(root)
    end

    def allows_path?(path)
      !enabled? || PaneyardSandbox.inside?(path, root)
    end

    def guard_path!(path, action)
      return if allows_path?(path)

      raise Violation, "sandbox refuses to #{action} #{path}: it is outside #{root}"
    end

    # Sandbox push verification may only read local remotes inside its root.
    # Network remotes (nil local_path) and copied production origins are refused.
    def guard_git_remote!(local_path)
      return unless enabled?
      return if local_path.present? && allows_path?(local_path)

      raise Violation, "sandbox refuses to verify a remote outside its root"
    end

    # A runner without a checkout of a workspace clones one
    # (Runner::Repositories.ensure_checkout). A sandbox clones only into its
    # own root, and only from an origin there: `origin_path` is the origin as
    # a local directory, nil for a network URL, which is always refused.
    def guard_clone!(path:, origin_path:)
      return unless enabled?

      guard_path!(path, "clone a repository into")
      return if origin_path.present? && allows_path?(origin_path)

      raise Violation, "sandbox refuses to clone from an origin outside #{root}"
    end

    # Starting a new project makes a GitHub repository (Runner::GitHub), which
    # no sandbox may do, real herdr or not.
    def guard_github!(action)
      return unless enabled?

      raise Violation, "sandbox refuses to #{action}: GitHub is outside #{root}"
    end

    RUNNER_URLS_ENV_VAR = "PANEYARD_SANDBOX_RUNNER_URLS".freeze

    # The runner-only processes this sandbox started itself (bin/sandbox's
    # remote runner), by url. A sandbox calls no other runner: bin/preflight's
    # database may be a production copy, whose remote runners are the
    # operator's real machines.
    def runner_urls
      ENV.fetch(RUNNER_URLS_ENV_VAR, "").split(",").map { |url| normalize_url(url) }.reject(&:empty?)
    end

    def allows_runner_url?(url)
      return true unless enabled?

      normalized = normalize_url(url)
      loopback_url?(normalized) && runner_urls.include?(normalized)
    end

    def guard_runner_url!(url)
      return if allows_runner_url?(url)

      raise Violation, "sandbox refuses to call the runner at #{url}: it is not one this sandbox started"
    end

    def loopback_url?(url)
      host = URI(url).hostname.to_s
      host == "localhost" || IPAddr.new(host).loopback?
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      false
    end

    def normalize_url(url)
      url.to_s.strip.delete_suffix("/")
    end

    # Only a process started by the fake herdr may be signalled: a copied
    # database's run_sessions.pid belongs to a real agent on this machine.
    # With real herdr, the sandbox's own sessions run real CLIs, and a pid one
    # of them recorded is fair game (a real-herdr sandbox never runs on a
    # production copy).
    def allows_signal?(pid)
      return true unless enabled?
      return RunSession.where(pid: pid.to_i.abs).exists? if real_herdr?

      command, _status = Open3.capture2("ps", "-o", "command=", "-p", pid.to_i.abs.to_s)
      command.include?("fake_agent")
    rescue SystemCallError
      false
    end
  end
end
