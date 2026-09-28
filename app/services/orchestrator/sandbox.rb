require "open3"

module Orchestrator
  # The in-app side of a sandbox instance (bin/sandbox, bin/preflight; see
  # WorkflowSandbox): an isolated copy of this app booted from a worktree to
  # exercise a change before it is merged. When WORKFLOW_SANDBOX=1 everything
  # that would reach outside that copy is refused here, whatever its database
  # happens to contain -- bin/preflight boots against a copy of production's,
  # full of real workspace paths and real session pids:
  #
  #   - herdr: only the sandbox's fake herdr socket, never the operator's;
  #   - git worktrees: provisioning and removal only under the sandbox root;
  #   - processes: a session pid is only signalled if it is a fake agent;
  #   - remote control (Telegram, and any other RemoteControl adapter): no
  #     credentials, so no polling or sending;
  #   - GitHub: no installation or `gh` token handed to a session.
  #
  # Two of those can be opted back in, for an operator who wants to see the
  # real thing (`bin/sandbox start --real-herdr --telegram`), never by
  # bin/preflight, whose database may be a production copy:
  #
  #   - WORKFLOW_SANDBOX_REAL_HERDR=1: runs open real sessions (the real CLI,
  #     real model usage) in the operator's own herdr, labelled [sandbox];
  #     signals are then allowed to pids this sandbox's own sessions recorded.
  #   - WORKFLOW_SANDBOX_TELEGRAM=1: the TELEGRAM_* env it was started with
  #     (bin/sandbox insists on a bot of its own) is used for real. Any other
  #     remote-control adapter opts in the same way, by its own name
  #     (allows_remote_control?).
  module Sandbox
    module_function

    class Violation < StandardError; end

    LABEL_PREFIX = "[sandbox] ".freeze

    def enabled?
      WorkflowSandbox.enabled?
    end

    def real_herdr?
      enabled? && ENV["WORKFLOW_SANDBOX_REAL_HERDR"] == "1"
    end

    # Whether a remote-control adapter (RemoteControl::Adapter) may reach its
    # platform. Outside a sandbox, always. Inside one, only an adapter
    # bin/sandbox opted in by name (WORKFLOW_SANDBOX_<NAME>=1, e.g. --telegram):
    # an adapter that polls would otherwise take the operator's messages from
    # production, and any adapter would answer from a sandbox as if it were
    # the real thing. A new adapter is therefore off in a sandbox by default.
    def allows_remote_control?(adapter_name)
      !enabled? || ENV["WORKFLOW_SANDBOX_#{adapter_name.to_s.upcase}"] == "1"
    end

    # What a sandbox shows in the operator's herdr (workspace names,
    # notifications) is marked, so it is never mistaken for a production run.
    def label(text)
      return text unless enabled?
      return text if text.to_s.start_with?(LABEL_PREFIX)

      "#{LABEL_PREFIX}#{text}"
    end

    def root
      WorkflowSandbox.root
    end

    def herdr_socket_path
      WorkflowSandbox.herdr_socket_path(root)
    end

    def allows_path?(path)
      !enabled? || WorkflowSandbox.inside?(path, root)
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
