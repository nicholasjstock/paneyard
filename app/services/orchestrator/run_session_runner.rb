module Orchestrator
  # Rails-owned lifecycle for a run's one interactive session: start it in a
  # herdr pane with the task in hand, steer it, observe it, end it.
  #
  # Everything about the pty and the process belongs to herdr, on the runner's
  # machine, and this module reaches it only through the run's runner
  # (Orchestrator::Runner). What Rails owns is the bookkeeping -- which pane,
  # which pid, which CLI session id -- and the two things herdr cannot infer:
  # that a run is finished, and that its concurrency slot is free.
  #
  # Accepted trade-off, unchanged from the original interactive-mode work: a
  # real interactive TUI's output is human-rendered, not structured JSON, so
  # there is no cost/usage/token accounting for a session. That was only ever
  # recoverable from `--print --output-format stream-json`, which is exactly
  # the mode this design abandons in order to let an operator watch the real
  # thing. Do not treat missing cost data as a bug. (The one thing that IS
  # recoverable is the CLI's own session id, which herdr reports via
  # agent.get's agent_session -- see #refresh!.)
  module RunSessionRunner
    module_function

    class Error < StandardError; end

    # How much of the agent pane a failed launch keeps in the run record. The
    # tail is what matters (the shell's last error, the CLI's exit message).
    LAUNCH_SCREEN_LINES = 80
    LAUNCH_SCREEN_MAX_CHARS = 8_000
    # start! owns a "starting" session: see refresh!. Well beyond the longest
    # start! can take (shell settling, launch retries, readiness, pid poll), so
    # past this the worker that was starting it must have died.
    STARTING_GRACE = 10.minutes

    # Provisions the run's worktree, which herdr opens as the session's
    # workspace, builds the layout in it and launches the agent.
    def start!(run, resume_session_id: nil, prompt: nil)
      capability_token, digest = RunSession.issue_capability
      session = run.run_sessions.create!(
        driver: run.launcher_variant, model: run.model.presence || DefaultModels.for(run.launcher_variant),
        status: "starting", capability_token_digest: digest
      )

      begin
        runner = runner_for(session)
        # herdr makes the worktree and its workspace in one call; both are
        # recorded before anything else, so a launch that fails -- or a worker
        # that dies mid-launch -- still leaves a pane to read, a workspace to
        # close, and a worktree the janitor knows belongs to this run.
        GitWorktree.provision!(run, session:)
        spec = session_spec(run:, session:, capability_token:, resume_session_id:, prompt:)

        # The workspace's layout: the agent pane plus whatever tabs and splits
        # the workspace is configured with (nvim beside it, by default). Only
        # the agent pane is recorded.
        opened = runner.open_session(spec)
        session.update!(
          herdr_workspace_id: opened.fetch("workspace_id"),
          herdr_tab_id: opened.fetch("tab_id"),
          herdr_pane_id: opened.fetch("pane_id"),
          mcp_config_path: opened.fetch("mcp_config_path"), prompt_path: opened.fetch("prompt_path")
        )

        pid = runner.launch_agent(spec, pane_id: session.herdr_pane_id, mcp_config_path: session.mcp_config_path)
        session.update!(status: "running", pid:, started_at: Time.current, last_seen_at: Time.current)
        session
      rescue StandardError => error
        # Closing the workspace destroys the only evidence of why the agent
        # did not start (a shell error, the CLI's own exit message), so read
        # the pane first.
        screen = launch_failure_screen(session)
        close_herdr_workspace(session)
        session.update!(
          status: "failed", outcome: "failed", result: launch_failure_result(error, session, screen),
          ended_at: Time.current
        )
        raise
      end
    end

    # Everything the runner needs to open this session, as plain data (see
    # Runner::Local): the herdr workspace provisioning opened, and the model,
    # MCP endpoint, prompt and layout resolved here. No environment: the
    # session's identity is its capability, which the runner puts in the
    # CLI's own config (Runner::SessionArgs).
    def session_spec(run:, session:, capability_token:, resume_session_id: nil, prompt: nil)
      {
        run_id: run.run_id,
        label: run.worktree_name.presence || run.run_id,
        driver: run.launcher_variant,
        model: session.model,
        cwd: run.target_root,
        capability_token:,
        resume_session_id:,
        prompt: prompt || RunPrompt.compose(run:, session_driver: run.launcher_variant),
        mcp_url:,
        layout: WorkspaceLayout.for(run.workspace),
        herdr_workspace_id: session.herdr_workspace_id,
        herdr_tab_id: session.herdr_tab_id,
        herdr_pane_id: session.herdr_pane_id
      }
    end

    # This orchestrator's /mcp endpoint, as a session reaches it.
    def mcp_url
      base = ENV.fetch("PANEYARD_RAILS_URL", "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}")
      "#{base}/mcp"
    end

    # Best effort by design: nothing here may mask the launch error itself.
    def launch_failure_screen(session)
      text = snapshot(session, lines: LAUNCH_SCREEN_LINES, source: "recent_unwrapped")
      return nil if text.blank?

      text = text.rstrip
      text.length > LAUNCH_SCREEN_MAX_CHARS ? "[...]\n#{text[-LAUNCH_SCREEN_MAX_CHARS..]}" : text
    rescue StandardError => error
      Rails.logger.warn("[RunSessionRunner] could not read #{session.herdr_pane_id} after a failed launch: #{error.message}")
      nil
    end

    def launch_failure_result(error, session, screen)
      return error.message if screen.nil?

      # claude's folder-trust gate defaults to "No, exit", so an untrusted
      # repo looks like a CLI that quit on its own. Say what it was.
      hint = "\n\nclaude stopped at its folder-trust prompt although Paneyard marks each worktree as trusted: " \
             "check that CLAUDE_CONFIG_DIR is the same for Paneyard and for " \
             "your login shell, and the log for a warning about it." if screen.match?(/trust this folder/i)
      "#{error.message}#{hint}\n\n--- Last screen of agent pane #{session.herdr_pane_id} ---\n#{screen}"
    end

    # Submits text as the agent's own live input. This is the operator's
    # steering wheel (the Herdr pane and remote-control adapters) and the inbound path for a
    # pull-request comment -- it is what replaced the whole blocking-question
    # protocol, because there is now always a live session to say it to.
    def prompt!(session, text)
      raise Error, "session #{session.id} is not live" unless session.live?
      raise Error, "session #{session.id} has no pane" if session.pane_gone?

      runner_for(session).send_prompt(session.herdr_pane_id, text)
      session.update!(status: "running", last_seen_at: Time.current)
      session
    end

    # Polls herdr for what it knows about the pane. Returns the session.
    #
    # Two things are recorded: agent_status (herdr's own
    # idle/working/blocked/done enum, which operator clients render) and the
    # CLI's own session id, which is the only way to get a --resume id for an
    # interactive session -- there is no structured log to parse one out of.
    #
    # A session start! is still launching is left alone. Before agent.start
    # herdr has no agent in the pane, so agent.get answers "not found" -- which
    # used to mark the session lost, complete the run, and let
    # RunSessionReconcileJob remove its still-clean worktree, all while start!
    # was about to launch the CLI into that now-deleted directory (it exits
    # at once; herdr never sees it start). start!'s own rescue already fails
    # a launch that goes wrong.
    def refresh!(session)
      return session if session.ended?
      return session if session.status == "starting" && session.created_at > STARTING_GRACE.ago
      return mark_pane_lost!(session) if session.pane_gone?

      # Raises Runner::Unreachable if herdr never answered at all -- a socket
      # blip or a restart, not confirmation the pane is gone -- so that
      # RunSessionReconcileJob's own rescue leaves every live session alone and
      # retries next minute, instead of this session's real "done"/"blocked"
      # report (already recorded by RunIdleReport) getting overwritten with a
      # false "failed".
      agent = runner_for(session).agent_state(session.herdr_pane_id)
      return mark_pane_lost!(session) if agent.nil?

      attributes = { agent_status: agent["agent_status"], last_seen_at: Time.current }
      cli_session_id = agent["cli_session_id"]
      attributes[:cli_session_id] = cli_session_id if cli_session_id.present?
      session.update!(**attributes)

      # The pane is alive but the process behind it is gone: the operator
      # quit the CLI, or it crashed. Either way the run is over and its slot
      # must be released -- no further report can arrive.
      mark_process_lost!(session) unless process_alive?(session)
      session
    end

    def snapshot(session, lines: 60, source: "recent")
      return nil if session.pane_gone?

      runner_for(session).snapshot(session.herdr_pane_id, lines:, source:)
    end

    # Ends the session for real. An interactive CLI never exits on its own
    # once a turn is over -- confirmed live that the same process group stays
    # foreground indefinitely after the model finishes responding -- so
    # "finished" only becomes "process gone" because something calls this.
    # Without it a run would hold its concurrency slot forever.
    #
    # close_workspace: false leaves the herdr workspace open for the caller,
    # which is how SessionClose removes a worktree herdr's way (worktree.remove
    # needs it open, and closes it) without herdr having to reopen it.
    def finish!(session, outcome:, result: nil, close_workspace: true)
      kill_process(session)
      close_herdr_workspace(session) if close_workspace
      # ended_at is what actually frees the slot; status is only descriptive,
      # and must not be left at a live-looking value like "blocked" (which
      # means "waiting at a question", not "gave up and handed the run back").
      session.update!(
        status: outcome == "done" ? "done" : "failed",
        outcome:, result:, ended_at: Time.current, herdr_pane_id: nil
      )
      notify(session, outcome:)
      session
    end

    def kill_process(session)
      return if session.pid.blank? || session.pid.to_i <= 0

      runner_for(session).terminate(session.pid)
    end

    def process_alive?(session)
      return true if session.pid.blank? || session.pid.to_i <= 0

      runner_for(session).process_alive?(session.pid)
    end

    def close_herdr_workspace(session)
      runner_for(session).close_workspace(session.herdr_workspace_id) if session.herdr_workspace_id.present?
    end

    # The agent pane is gone, but the rest of its herdr workspace may not be:
    # the operator can close just the agent's pane or tab, leaving a layout's
    # log tail or dev server running -- inside a worktree WorktreeJanitor is
    # about to reclaim. The session is over either way, so close the lot.
    def mark_pane_lost!(session)
      outcome = last_reported_outcome(session)
      session.update!(
        status: outcome == "done" ? "done" : "failed", outcome:, herdr_pane_id: nil, ended_at: Time.current,
        result: session.result.presence || "The herdr pane for this session no longer exists."
      )
      kill_process(session)
      close_herdr_workspace(session)
      session
    end

    def mark_process_lost!(session)
      finish!(
        session, outcome: last_reported_outcome(session),
        result: session.result.presence || "The session's CLI process exited without reporting a result."
      )
    end

    # A pane or process disappearing does not undo a report the session
    # already made -- a session that reported "done" (work committed, pushed,
    # maybe merged) and then lost its pane before the operator closed it is
    # not a failed run, whatever killed the pane. The session's own last
    # checkpoint is its most recent word on how the run actually stands, so
    # trust that over guessing "failed". Only a session that never reported
    # anything falls back to "failed".
    def last_reported_outcome(session)
      session.checkpoints.last&.outcome || "failed"
    end

    def notify(session, outcome:)
      runner_for(session).notify(
        title: "Run #{session.run.run_id} #{outcome}",
        body: session.run.task.to_s.truncate(140),
        sound: outcome == "done" ? "done" : "request"
      )
    end

    def runner_for(session)
      Runner.for(session.run.workspace)
    end
  end
end
