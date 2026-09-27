require "fileutils"

module Orchestrator
  # Rails-owned lifecycle for a run's one interactive session: start it in a
  # herdr pane with the task in hand, steer it, observe it, end it.
  #
  # Everything about the pty and the process belongs to herdr (see
  # Orchestrator::Herdr). What Rails owns is the bookkeeping -- which pane,
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

    READY_POLL_ATTEMPTS = 120
    READY_POLL_INTERVAL_SECONDS = 0.5
    PID_POLL_ATTEMPTS = 40
    PID_POLL_INTERVAL_SECONDS = 0.25
    CODEX_TRUST_PROMPT_GRACE_SECONDS = 2
    SHELL_POLL_ATTEMPTS = 80
    SHELL_POLL_INTERVAL_SECONDS = 0.25
    # herdr rejects agent.start unless the target pane is idle at its own
    # prompt, so one clear sample is not enough: the operator's shell rc files
    # run in bursts with idle gaps between them, and a single idle reading can
    # be one of those gaps rather than the end of startup.
    SHELL_STABLE_SAMPLES = 3
    AGENT_START_ATTEMPTS = 5
    # A healthy launch is detected about 250 ms after agent.start (herdr logs
    # "agent changed ... agent=Some(Claude)"), so 10 s is ample and still well
    # inside herdr's own 30 s startup timeout -- see wait_for_agent_detected!.
    AGENT_DETECT_POLL_ATTEMPTS = 40
    AGENT_DETECT_POLL_INTERVAL_SECONDS = 0.25
    # How much of the agent pane a failed launch keeps for the run screen. The
    # tail is what matters (the shell's last error, the CLI's exit message).
    LAUNCH_SCREEN_LINES = 80
    LAUNCH_SCREEN_MAX_CHARS = 8_000
    # start! owns a "starting" session: see refresh!. Well beyond the longest
    # start! can take (shell settling, launch retries, readiness, pid poll), so
    # past this the worker that was starting it must have died.
    STARTING_GRACE = 10.minutes
    PROMPT_SUBMIT_POLL_ATTEMPTS = 8
    PROMPT_SUBMIT_POLL_INTERVAL_SECONDS = 0.5

    def start!(run, resume_session_id: nil, prompt: nil)
      raise Error, "run #{run.run_id} has no provisioned worktree" if run.target_root.blank? || run.branch_name.blank?

      capability_token, digest = RunSession.issue_capability
      session = run.run_sessions.create!(
        driver: run.launcher_variant, model: run.model.presence || SessionArgs.default_model(run.launcher_variant),
        status: "starting", capability_token_digest: digest
      )

      begin
        runtime_dir = runtime_dir_for(run)
        mcp_config_path = File.join(runtime_dir, "mcp.json")
        SessionArgs.write_claude_mcp_config(mcp_config_path, capability_token) if run.launcher_variant == "claude"

        kind, args, extra_env = SessionArgs.build(
          driver: run.launcher_variant, root_dir: run.target_root,
          mcp_config_path:, capability_token:, resume_session_id:, model: run.model
        )
        env = SessionEnv.for_session(run:, capability_token:, extra: extra_env)

        text = prompt || RunPrompt.compose(run:, session_driver: run.launcher_variant)
        prompt_path = File.join(runtime_dir, "prompt.txt")
        File.write(prompt_path, text)

        # The workspace's layout: the agent pane plus whatever tabs and splits
        # the workspace is configured with (nvim beside it, by default). Only
        # the agent pane is recorded -- see SessionLayout.
        root_pane = SessionLayout.open!(
          label: run.worktree_name.presence || run.run_id, cwd: run.target_root, env:,
          tabs: WorkspaceLayout.for(run.workspace)
        )
        session.update!(
          herdr_workspace_id: root_pane.fetch("workspace_id"),
          herdr_tab_id: root_pane.fetch("tab_id"),
          herdr_pane_id: root_pane.fetch("pane_id"),
          mcp_config_path:, prompt_path:
        )

        pane_id = session.herdr_pane_id
        start_agent!(name: run.run_id, kind:, pane_id:, args:)
        wait_for_agent_detected!(pane_id, kind:)
        dismiss_codex_trust_prompt!(pane_id) if run.launcher_variant == "codex"
        wait_until_ready!(pane_id, kind:)
        Herdr.agent_prompt(pane_id, text)
        submit_prompt_if_unsent!(pane_id)

        pid = wait_for_pid(pane_id)
        raise Error, "session for run #{run.run_id} never started a foreground process" unless pid

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

      "#{error.message}\n\n--- Last screen of agent pane #{session.herdr_pane_id} ---\n#{screen}"
    end

    # Submits text as the agent's own live input. This is the operator's
    # steering wheel (the run screen's message box) and the inbound path for a
    # pull-request comment -- it is what replaced the whole blocking-question
    # protocol, because there is now always a live session to say it to.
    def prompt!(session, text)
      raise Error, "session #{session.id} is not live" unless session.live?
      raise Error, "session #{session.id} has no pane" if session.pane_gone?

      Herdr.agent_prompt(session.herdr_pane_id, text)
      session.update!(status: "running", last_seen_at: Time.current)
      session
    end

    # Polls herdr for what it knows about the pane. Returns the session.
    #
    # Two things are recorded: agent_status (herdr's own
    # idle/working/blocked/done enum, which the run screen renders) and the
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

      begin
        agent = Herdr.agent_get(session.herdr_pane_id)
      rescue Herdr::Unreachable
        # herdr never answered at all -- a socket blip or a restart, not
        # confirmation the pane is gone. Re-raise so RunSessionReconcileJob's
        # own rescue leaves every live session alone and retries next minute,
        # instead of this session's real "done"/"blocked" report (already
        # recorded by RunIdleReport) getting overwritten with a false "failed".
        raise
      rescue Herdr::Error
        return mark_pane_lost!(session)
      end

      attributes = { agent_status: agent["agent_status"], last_seen_at: Time.current }
      cli_session_id = agent.dig("agent_session", "value")
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

      Herdr.pane_read(session.herdr_pane_id, source:, lines:)
    rescue Herdr::Error
      nil
    end

    # Ends the session for real. An interactive CLI never exits on its own
    # once a turn is over -- confirmed live that the same process group stays
    # foreground indefinitely after the model finishes responding -- so
    # "finished" only becomes "process gone" because something calls this.
    # Without it a run would hold its concurrency slot forever.
    def finish!(session, outcome:, result: nil)
      kill_process(session)
      close_herdr_workspace(session)
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
      return unless Sandbox.allows_signal?(session.pid)

      Process.kill("SIGTERM", -session.pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def process_alive?(session)
      return true if session.pid.blank? || session.pid.to_i <= 0

      Process.kill(0, session.pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def close_herdr_workspace(session)
      Herdr.workspace_close(session.herdr_workspace_id) if session.herdr_workspace_id.present?
    rescue Herdr::Error
      nil
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
      Herdr.notify(
        title: "Run #{session.run.run_id} #{outcome}",
        body: session.run.task.to_s.truncate(140),
        sound: outcome == "done" ? "done" : "request"
      )
    end

    # codex shows a one-time-per-directory "Do you trust the contents of this
    # directory?" gate on startup that is entirely separate from
    # sandbox/approval settings -- confirmed live it survives
    # `-s danger-full-access`, and neither agent.prompt nor a raw send_text
    # can answer it (they land after the gate is already resolved). A plain
    # Enter accepts its pre-highlighted default ("1. Yes, continue") and was
    # confirmed live to work reliably. A fixed grace period rather than
    # polling, because herdr's readiness detection was observed to report
    # interactive_ready=true while still sitting at this gate -- there is no
    # state-based signal to poll instead. Harmless on an already-trusted
    # directory: the pane is still at codex's own startup screen, before any
    # prompt text has been sent, so a stray Enter has nothing to submit.
    def dismiss_codex_trust_prompt!(pane_id)
      sleep CODEX_TRUST_PROMPT_GRACE_SECONDS
      Herdr.agent_send_keys(pane_id, [ "Enter" ])
    end

    # workspace.create returns a pane whose shell exists immediately, but that
    # shell then runs the operator's own rc files -- confirmed live on this
    # machine: pyenv-rehash (which forks bash and chmod), starship's prompt
    # init, and git. herdr refuses agent.start while any of that holds the
    # pane's foreground ("... is not an available shell"), and because Rails
    # writes the session row between the two calls, agent.start reliably landed
    # mid-startup rather than intermittently. So wait for the pane to be idle
    # before launching, and still retry the launch itself: the gap between the
    # last poll and agent.start is not something the poll can close, and rc
    # files that fire on a timer can reclaim the foreground inside it.
    #
    # foreground_process_group_id == shell_pid is NOT a sufficient signal
    # (confirmed live: it matched while starship and bash were still running).
    # The reliable one is the foreground process list being exactly the shell.
    def start_agent!(name:, kind:, pane_id:, args:)
      attempts = 0
      begin
        attempts += 1
        wait_for_available_shell!(pane_id)
        Herdr.agent_start(name:, kind:, pane_id:, args:)
      rescue Herdr::Error => error
        raise if attempts >= AGENT_START_ATTEMPTS || !error.message.include?("not an available shell")

        sleep SHELL_POLL_INTERVAL_SECONDS
        retry
      end
    end

    def wait_for_available_shell!(pane_id)
      stable = 0
      SHELL_POLL_ATTEMPTS.times do
        if shell_idle?(pane_id)
          stable += 1
          return true if stable >= SHELL_STABLE_SAMPLES
        else
          stable = 0
        end
        sleep SHELL_POLL_INTERVAL_SECONDS
      end
      raise Error, "pane #{pane_id} never settled at an idle shell prompt"
    end

    def shell_idle?(pane_id)
      info = Herdr.pane_process_info(pane_id)
      foreground = Array(info["foreground_processes"])
      foreground.one? && foreground.first["pid"] == info["shell_pid"]
    rescue Herdr::Error
      false
    end

    # agent.prompt normally submits on its own -- confirmed live, including
    # with this app's real ~5KB composed prompt. But it was also observed once
    # on a real run to deliver the text and leave it sitting unsubmitted in
    # Claude's input box: the session stayed idle forever, holding its
    # concurrency slot, and a single Enter submitted it. That was not
    # reproducible in isolation, so rather than always send an Enter, confirm
    # the agent actually picked the prompt up and only nudge it if it did not.
    # An Enter on an already-submitted (empty) input box does nothing.
    def submit_prompt_if_unsent!(pane_id)
      PROMPT_SUBMIT_POLL_ATTEMPTS.times do
        return true unless agent_idle?(pane_id)

        sleep PROMPT_SUBMIT_POLL_INTERVAL_SECONDS
      end
      Herdr.agent_send_keys(pane_id, [ "Enter" ])
      false
    end

    def agent_idle?(pane_id)
      Herdr.agent_get(pane_id)["agent_status"].to_s == "idle"
    rescue Herdr::Error
      false
    end

    # agent.start only types the command line into the pane's shell; it
    # returns before anything has run. herdr then detects the CLI by its
    # foreground process, and agent.get's `agent` goes from null to the CLI's
    # name ("claude") -- the moment herdr logs "agent changed ...
    # previous_agent=None agent=Some(Claude) process=claude". Until then
    # agent.get still answers, with no `agent`, and if detection never comes
    # herdr silently drops the launch after agent.start's timeout_ms (30 s by
    # default) and agent.get turns into an opaque "agent target ... not
    # found". Checking for detection directly fails in seconds, with a message
    # that says what actually went wrong.
    #
    # No second agent.start on failure. By now nothing says whether the
    # command line was swallowed by the shell or the CLI ran and exited, or is
    # still coming up under load: in that last case a retry types a second
    # shell command into the live CLI's input box. And the one cause found so
    # far (the CLI launched into a worktree that had been removed -- see
    # refresh!) would fail identically a second time.
    def wait_for_agent_detected!(pane_id, kind:)
      AGENT_DETECT_POLL_ATTEMPTS.times do
        return true if agent_info!(pane_id, kind:, waiting_for: "start")["agent"].present?

        sleep AGENT_DETECT_POLL_INTERVAL_SECONDS
      end
      seconds = (AGENT_DETECT_POLL_ATTEMPTS * AGENT_DETECT_POLL_INTERVAL_SECONDS).round
      raise Error, "herdr never detected #{kind} starting in pane #{pane_id} after #{seconds}s: " \
                   "the command line was typed into the pane's shell, but no #{kind} process appeared"
    end

    def wait_until_ready!(pane_id, kind:)
      READY_POLL_ATTEMPTS.times do
        return true if agent_info!(pane_id, kind:, waiting_for: "become ready")["interactive_ready"]

        sleep READY_POLL_INTERVAL_SECONDS
      end
      raise Error, "herdr agent in pane #{pane_id} never became ready"
    end

    # agent.get during a launch, with herdr's "agent target ... not found"
    # (herdr has given up on the launch) turned into a plain explanation.
    # Anything else, including herdr being unreachable, propagates as is.
    def agent_info!(pane_id, kind:, waiting_for:)
      Herdr.agent_get(pane_id)
    rescue Herdr::Unreachable
      raise
    rescue Herdr::Error => error
      raise unless error.message.match?(/agent target .* not found/)

      raise Error, "herdr stopped tracking the #{kind} launch in pane #{pane_id} while waiting for it to " \
                   "#{waiting_for} (herdr: #{error.message}); herdr drops an agent.start it has not " \
                   "seen become ready within its startup timeout, so #{kind} most likely never started or exited"
    end

    # A pane's foreground_process_group_id equals its shell_pid while it sits
    # idle at its own prompt, and changes to the job-control process group of
    # whatever the shell runs the moment agent.start's launch lands. That
    # group id is the session's pid, and matches kill_process's `kill -pid`
    # convention.
    def wait_for_pid(pane_id)
      PID_POLL_ATTEMPTS.times do
        info = Herdr.pane_process_info(pane_id)
        group_id = info.fetch("foreground_process_group_id")
        return group_id if group_id != info.fetch("shell_pid")

        sleep PID_POLL_INTERVAL_SECONDS
      end
      nil
    end

    def runtime_dir_for(run)
      dir = Rails.root.join("tmp", "run_sessions", ArtifactStore.sanitize_run_id(run.run_id))
      FileUtils.mkdir_p(dir)
      dir.to_s
    end
  end
end
