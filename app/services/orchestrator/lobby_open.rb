module Orchestrator
  # Opens a workspace's lobby (Lobby): the operator's own agent session on the
  # repository's checkout, where they integrate -- queue jobs, read their
  # reports, merge their branches -- on the default branch, a pull request's
  # branch, or any other. The herdr plugin's lobby action and /mcp/admin's
  # open_lobby call this; a run session cannot, since it switches the
  # operator's checkout.
  #
  # The lobby is the checkout itself, so it is on one branch at a time and a
  # workspace has at most one. Opening it again on the branch it is on finds
  # the one already open; opening it on another branch while it is live is
  # refused, since the checkout would change under its agent. Once its agent
  # is gone, the next open closes what is left of its herdr workspace and
  # opens a new one.
  #
  # A lobby is not a run: it holds no concurrency slot, gets no task and no
  # capability (its CLI talks to /mcp/admin), never reports, and nothing
  # reconciles it. The agent starts with nothing typed into it; the operator
  # speaks first.
  module LobbyOpen
    module_function

    # A live lobby is on another branch.
    class Busy < StandardError; end

    # A lobby row whose agent has not been recorded yet is still being opened
    # (by another call), not dead. Well beyond the longest a launch takes, as
    # RunSessionRunner::STARTING_GRACE is.
    OPENING_GRACE = 10.minutes

    # Returns { state: "opened" | "already_open", lobby:, switched_from: }:
    # switched_from is the branch the checkout was on, when opening the lobby
    # switched it.
    #
    # With no branch named, the lobby stays where the checkout is: on the
    # branch it has checked out, or, when one is live, wherever that one is.
    def call(workspace, branch: nil, driver: nil, model: nil)
      branch = branch.to_s.strip.presence
      raise ArgumentError, "`#{branch}` is not a valid branch name" if branch && !GitRef.branch?(branch)

      driver = driver.to_s.strip.presence || "claude"
      raise ArgumentError, "driver must be one of #{Run::LAUNCHER_VARIANTS.join(', ')}" unless Run::LAUNCHER_VARIANTS.include?(driver)

      runner = Runner.for(workspace)
      if (existing = workspace.open_lobby)
        if live?(existing)
          return { state: "already_open", lobby: existing, switched_from: nil } if branch.nil? || existing.branch == branch

          raise Busy, "The #{workspace.name} lobby is open on #{existing.branch}. Quit its agent or close its herdr " \
            "workspace first, then open it on #{branch}."
        end
        retire!(existing, runner)
      end
      branch ||= runner.checkout_branch(repository_path: workspace.repository_path) ||
        raise(ArgumentError, "#{workspace.repository_path} is on a detached HEAD; name the branch to open the lobby on")

      # Claimed before the checkout is touched: the partial unique index
      # makes a second, concurrent open fail here rather than switch the
      # checkout under the first.
      lobby = workspace.lobbies.create!(branch:, driver:, model: model.to_s.strip.presence || DefaultModels.for(driver))
      open!(lobby, runner)
    rescue ActiveRecord::RecordNotUnique
      raise Busy, "The #{workspace.name} lobby is being opened already."
    end

    # The workspace's open lobby and whether its agent is still there, as
    # { lobby:, live: }, or nil when it has none. Only looks.
    def status(workspace)
      lobby = workspace.open_lobby
      lobby && { lobby:, live: live?(lobby) }
    end

    # Whether the lobby's agent is still running. herdr not answering says
    # nothing about the pane, so counts as live.
    def live?(lobby)
      return lobby.created_at > OPENING_GRACE.ago if lobby.herdr_pane_id.blank? || lobby.pid.blank?

      runner = Runner.for(lobby.workspace)
      runner.agent_state(lobby.herdr_pane_id).present? && runner.process_alive?(lobby.pid)
    rescue Runner::Unreachable
      true
    end

    def open!(lobby, runner)
      workspace = lobby.workspace
      switched = runner.switch_checkout(repository_path: workspace.repository_path, branch: lobby.branch)
      opened = runner.open_checkout_workspace(repository_path: workspace.repository_path,
        label: "#{workspace.name} lobby (#{lobby.branch})")
      lobby.update!(herdr_workspace_id: opened.fetch("workspace_id"), herdr_pane_id: opened.fetch("pane_id"))

      spec = session_spec(lobby, opened)
      session = runner.open_session(spec)
      launched = runner.launch_agent(spec, pane_id: session.fetch("pane_id"), mcp_config_path: session.fetch("mcp_config_path"))
      lobby.update!(herdr_pane_id: session.fetch("pane_id"), pid: launched.fetch("pid"))

      { state: "opened", lobby:, switched_from: switched.fetch("switched") ? switched.fetch("previous_branch") : nil }
    rescue StandardError
      retire!(lobby, runner)
      raise
    end

    # What the runner needs to open the lobby's session, in the shape
    # RunSessionRunner.session_spec has, minus everything that makes it a
    # run's: no prompt, no capability, /mcp/admin.
    def session_spec(lobby, opened)
      {
        run_id: agent_name(lobby.workspace),
        label: "#{lobby.workspace.name} lobby",
        driver: lobby.driver,
        model: lobby.model,
        cwd: lobby.workspace.repository_path,
        capability_token: nil,
        resume_session_id: nil,
        prompt: nil,
        mcp_url: RunSessionRunner.mcp_url,
        mcp_endpoint: "admin",
        layout: WorkspaceLayout.for(lobby.workspace),
        herdr_workspace_id: opened.fetch("workspace_id"),
        herdr_tab_id: opened.fetch("tab_id"),
        herdr_pane_id: opened.fetch("pane_id")
      }
    end

    # herdr's agent.start takes a name of lowercase letters, digits, - and _,
    # starting with a letter, at most 32 characters (confirmed live: it
    # refused "lobby-gembani.com"). A run's run_id is one already; a
    # workspace's name, being the repository's directory name, need not be.
    def agent_name(workspace)
      "lobby-#{workspace.name.downcase.gsub(/[^a-z0-9_-]+/, '-')}"[0, 32].sub(/-+\z/, "")
    end

    # Closes what is left of the lobby's herdr workspace, which takes any
    # agent still in it down too, and forgets it.
    def retire!(lobby, runner)
      runner.close_workspace(lobby.herdr_workspace_id) if lobby.herdr_workspace_id.present?
      lobby.update!(closed_at: Time.current)
    end
  end
end
