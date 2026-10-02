require "open3"

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
