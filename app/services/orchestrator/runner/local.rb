module Orchestrator
  module Runner
    # The runner on this machine, in this process: herdr over its local
    # socket, git on local checkouts, signals to local pids. Its public methods
    # are the whole runner interface -- a runner on another machine would
    # answer the same calls with the same plain data -- and the modules beside
    # it (Runner::Herdr, SessionLauncher, SessionLayout, SessionArgs,
    # ProcessEnv, Worktrees, WorkspaceRoots, ModelDiscovery, Attachments) are its internals,
    # which nothing outside Orchestrator::Runner uses.
    #
    # Errors leave as Runner::Error (or Runner::Unreachable when herdr never
    # answered, Runner::LaunchError when an agent never came up); herdr's and
    # git's own errors do not cross.
    class Local
      attr_reader :runtime_root

      # runtime_root is where each session's runtime files (the CLI's MCP
      # config, its prompt) are written.
      def initialize(runtime_root: Rails.root.join("tmp", "run_sessions"))
        @runtime_root = runtime_root.to_s
      end

      # Identifies this runner, e.g. in cache keys for what it reports.
      def id
        "local"
      end

      # --- Worktrees --------------------------------------------------------

      # A worktree `name` beside source_root, on paneyard/<name>, from main.
      # Returns { "source_root", "target_root", "branch", "base_sha", "reused" }.
      def provision_worktree(source_root:, name:, current_target_root: nil)
        Worktrees.provision!(source_root:, name:, current_target_root:)
      end

      # Whether `path` is a live worktree of source_root that git knows about.
      def worktree_registered?(source_root:, path:)
        Worktrees.registered?(source_root:, path:)
      end

      # Removes `path` if its work is committed and on main or a remote
      # branch. Returns whether it did.
      def release_worktree(source_root:, path:)
        Worktrees.release(source_root:, path:)
      end

      # Removes `path`; refuses a dirty worktree unless `force`.
      def remove_worktree(source_root:, path:, force: false)
        Worktrees.remove(source_root:, path:, force:)
      end

      # Removes every worktree of source_root whose work is saved elsewhere,
      # except the paths in `keep`. Returns how many it removed.
      def reclaim_worktrees(source_root:, keep:)
        Worktrees.reclaim(source_root:, keep:)
      end

      # The checkout's `origin` remote URL.
      def origin_url(path:)
        Worktrees.origin_url(path)
      end

      # Whether root_path is laid out as a workspace root: a `main` checkout
      # beneath it, on main, with an origin. Looks only; changes nothing.
      # Returns { "root_path" (expanded), "source_root", "origin_url",
      # "problems" => [{ "code", "message" }] }, problems empty when it is fine.
      def check_workspace_root(root_path:)
        WorkspaceRoots.check(root_path)
      end

      # --- Sessions ---------------------------------------------------------
      #
      # `spec` is the plain hash Orchestrator::RunSessionRunner.session_spec
      # builds: run_id, label, driver, model, cwd, capability_token, prompt,
      # mcp_url, workspace_env, env, github_token, ambient_github_auth, layout,
      # resume_session_id.

      # Returns { "workspace_id", "tab_id", "pane_id", "mcp_config_path",
      # "prompt_path" }.
      def open_session(spec)
        herdr { SessionLauncher.open(spec, runtime_root:) }
      end

      # Starts the agent in the pane open_session returned. Returns its pid.
      def launch_agent(spec, pane_id:, mcp_config_path:)
        herdr { SessionLauncher.launch(spec, pane_id:, mcp_config_path:) }
      end

      # { "agent_status", "cli_session_id" } for the agent in `pane_id`, or nil
      # when herdr says it is gone. Raises Unreachable when herdr never
      # answered, which says nothing about the pane.
      def agent_state(pane_id)
        agent = Herdr.agent_get(pane_id)
        { "agent_status" => agent["agent_status"], "cli_session_id" => agent.dig("agent_session", "value").presence }
      rescue Herdr::Unreachable => error
        raise Unreachable, error.message
      rescue Herdr::Error
        nil
      end

      # Submits text to the agent as its own live input.
      def send_prompt(pane_id, text)
        herdr { Herdr.agent_prompt(pane_id, text) }
        nil
      end

      # The pane's newest lines, or nil when it cannot be read.
      def snapshot(pane_id, lines:, source: "recent")
        Herdr.pane_read(pane_id, source:, lines:)
      rescue Herdr::Error
        nil
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # SIGTERM to the session's process group. Quietly does nothing when it is
      # already gone, or when a sandbox may not signal it.
      def terminate(pid)
        return unless Sandbox.allows_signal?(pid)

        Process.kill("SIGTERM", -pid)
        nil
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Closes the herdr workspace and every pane in it. Best effort.
      def close_workspace(workspace_id)
        Herdr.workspace_close(workspace_id)
        nil
      rescue Herdr::Error
        nil
      end

      # A desktop notification on this machine. Best effort.
      def notify(title:, body: nil, sound: "done")
        Herdr.notify(title:, body:, sound:)
        nil
      end

      # --- This machine -----------------------------------------------------

      # [{ "id", "label" }] the driver's installed CLI offers; [] if none.
      def available_models(driver)
        ModelDiscovery.models_for(driver)
      end

      # Stores a launch attachment for the run; returns its path.
      def store_attachment(source_root:, run_id:, name:, content:)
        Attachments.store(source_root, run_id, name, content)
      end

      # [{ "name", "content" }]
      def attachments(source_root:, run_id:)
        Attachments.list(source_root, run_id)
      end

      # Where the run's attachments are, as the session should be told.
      def attachments_dir(source_root:, run_id:)
        Attachments.dir(source_root, run_id)
      end

      private

      def herdr
        yield
      rescue Herdr::Unreachable => error
        raise Unreachable, error.message
      rescue Herdr::Error => error
        raise Error, error.message
      end
    end
  end
end
