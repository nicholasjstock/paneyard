module Orchestrator
  module Runner
    # The runner on this machine, in this process: herdr over its local
    # socket, git on local checkouts, signals to local pids. Its public methods
    # are the whole runner interface -- a runner on another machine would
    # answer the same calls with the same plain data -- and the modules beside
    # it (Runner::Herdr, SessionLauncher, SessionLayout, SessionArgs,
    # Worktrees, Repositories, ClaudeTrust, ModelDiscovery, Attachments) are
    # its internals, which nothing outside Orchestrator::Runner uses.
    #
    # Errors leave as Runner::Error (or Runner::Unreachable when herdr never
    # answered, Runner::LaunchError when an agent never came up); herdr's and
    # git's own errors do not cross.
    class Local
      attr_reader :runtime_root

      # runtime_root is where each session's runtime files (the CLI's MCP
      # config, its prompt) are written. PANEYARD_RUNTIME_DIR moves it out of
      # the app's tmp/: the herdr plugin keeps it in its state directory,
      # since a reinstall replaces the plugin's checkout under live sessions.
      def initialize(runtime_root: ENV["PANEYARD_RUNTIME_DIR"].presence || Rails.root.join("tmp", "run_sessions"))
        @runtime_root = runtime_root.to_s
      end

      # Identifies this runner, e.g. in cache keys for what it reports.
      def id
        "local"
      end

      # --- Worktrees --------------------------------------------------------
      #
      # herdr makes and removes run worktrees, wherever its own config puts
      # them; git decides what is safe to remove (Runner::Worktrees).

      # A worktree of repository_path on `branch`, from `base_branch`, opened
      # by herdr as the run's workspace; or, when current_target_root already
      # is one, that worktree reopened; or, when `branch` already exists, a
      # worktree on it as it is. Returns { "repository_path",
      # "target_root", "branch", "base_sha", "reused", "workspace_id",
      # "tab_id", "pane_id" }.
      def provision_worktree(repository_path:, branch:, base_branch:, label:, current_target_root: nil)
        Worktrees.provision!(repository_path:, branch:, base_branch:, label:, current_target_root:)
      end

      # nil when a run can start from `branch`, else { "code", "message" }.
      def base_branch_problem(repository_path:, branch:)
        Worktrees.base_branch_problem(repository_path, branch)
      end

      # Whether the repository has `branch` as a local branch.
      def branch_exists?(repository_path:, branch:)
        Worktrees.branch_exists?(repository_path:, branch:)
      end

      # Whether `branch` has commits beyond `since` and they are all in
      # `base_branch`: what a run another run is queued after must reach.
      def branch_merged?(repository_path:, branch:, base_branch:, since:)
        Worktrees.merged?(repository_path:, branch:, base_branch:, since:)
      end

      def verify_job_finished!(repository_path:, path:, branch:, base_branch:)
        Worktrees.verify_job_finished!(repository_path:, path:, branch:, base_branch:)
      end

      # Whether `path` is a linked worktree of the repository that git knows.
      def worktree_registered?(repository_path:, path:)
        Worktrees.registered?(repository_path:, path:)
      end

      # Removes `path` if it is clean and its HEAD is in base_branch or on a
      # remote branch. With branch supplied for explicit finalization, verifies
      # the actual run tip/base or push destination before removal.
      def release_worktree(repository_path:, path:, base_branch:, branch: nil)
        Worktrees.release(repository_path:, path:, base_branch:, branch:)
      end

      # Removes `path`; refuses a dirty worktree unless `force`.
      def remove_worktree(repository_path:, path:, force: false)
        Worktrees.remove(repository_path:, path:, force:)
      end

      # Releases each of `worktrees` ([{ "path", "base_branch" }]) whose work is
      # saved, and touches nothing else. Returns how many it removed.
      def reclaim_worktrees(repository_path:, worktrees:)
        Worktrees.reclaim(repository_path:, worktrees:)
      end

      # The checkout's `origin` remote URL.
      def origin_url(path:)
        Worktrees.origin_url(path)
      end

      # Whether `path` is a repository runs can start from, and its default
      # branch. Looks only; changes nothing. Returns { "repository_path",
      # "default_base_branch", "origin_url", "problems" => [{ "code",
      # "message" }] }, problems empty when it is fine.
      def check_repository(path:, default_base_branch: nil)
        Repositories.check(path, default_base_branch:)
      end

      # --- Sessions ---------------------------------------------------------
      #
      # `spec` is the plain hash Orchestrator::RunSessionRunner.session_spec
      # builds: run_id, label, driver, model, cwd, capability_token, prompt,
      # mcp_url, layout, resume_session_id, and the herdr workspace
      # provision_worktree opened (herdr_workspace_id, herdr_tab_id,
      # herdr_pane_id), which the session's layout is built in.

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

      # Finalization needs failures to be retryable rather than best effort.
      def close_workspace!(workspace_id)
        herdr { Herdr.workspace_close!(workspace_id) }
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

      # Stores a launch attachment for the run, beside its runtime files
      # rather than in the repository; returns its path.
      def store_attachment(run_id:, name:, content:)
        Attachments.store(runtime_root, run_id, name, content)
      end

      # [{ "name", "content" }]. `legacy_root` is the repository runs used to
      # keep attachments in (<checkout>/.paneyard/artifacts), still read for
      # runs from then.
      def attachments(run_id:, legacy_root: nil)
        Attachments.list(runtime_root, run_id, legacy_root:)
      end

      # Where the run's attachments are, as the session should be told.
      def attachments_dir(run_id:)
        Attachments.dir(runtime_root, run_id)
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
