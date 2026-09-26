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

    def start!(run, resume_session_id: nil, prompt: nil)
      raise Error, "run #{run.run_id} has no provisioned worktree" if run.target_root.blank? || run.branch_name.blank?

      capability_token, digest = RunSession.issue_capability
      session = run.run_sessions.create!(
        driver: run.launcher_variant, status: "starting", capability_token_digest: digest
      )

      begin
        runtime_dir = runtime_dir_for(run)
        mcp_config_path = File.join(runtime_dir, "mcp.json")
        SessionArgs.write_claude_mcp_config(mcp_config_path, capability_token) if run.launcher_variant == "claude"

        kind, args, extra_env = SessionArgs.build(
          driver: run.launcher_variant, root_dir: run.target_root,
          mcp_config_path:, capability_token:, resume_session_id:
        )
        env = SessionEnv.for_session(run:, capability_token:, extra: extra_env)

        text = prompt || RunPrompt.compose(run:, session_driver: run.launcher_variant)
        prompt_path = File.join(runtime_dir, "prompt.txt")
        File.write(prompt_path, text)

        root_pane = Herdr.workspace_create(
          label: run.worktree_name.presence || run.run_id, cwd: run.target_root, env:, focus: false
        ).fetch("root_pane")
        session.update!(
          herdr_workspace_id: root_pane.fetch("workspace_id"),
          herdr_tab_id: root_pane.fetch("tab_id"),
          herdr_pane_id: root_pane.fetch("pane_id"),
          mcp_config_path:, prompt_path:
        )

        pane_id = session.herdr_pane_id
        Herdr.agent_start(name: run.run_id, kind:, pane_id:, args:)
        dismiss_codex_trust_prompt!(pane_id) if run.launcher_variant == "codex"
        wait_until_ready!(pane_id)
        Herdr.agent_prompt(pane_id, text)

        pid = wait_for_pid(pane_id)
        raise Error, "session for run #{run.run_id} never started a foreground process" unless pid

        session.update!(status: "running", pid:, started_at: Time.current, last_seen_at: Time.current)
        session
      rescue StandardError => error
        close_herdr_workspace(session)
        session.update!(status: "failed", outcome: "failed", result: error.message, ended_at: Time.current)
        raise
      end
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
    def refresh!(session)
      return session if session.ended?
      return mark_pane_lost!(session) if session.pane_gone?

      begin
        agent = Herdr.agent_get(session.herdr_pane_id)
      rescue Herdr::Error
        return mark_pane_lost!(session)
      end

      attributes = { agent_status: agent["agent_status"], last_seen_at: Time.current }
      cli_session_id = agent.dig("agent_session", "value")
      attributes[:cli_session_id] = cli_session_id if cli_session_id.present?
      session.update!(**attributes)

      # The pane is alive but the process behind it is gone: the operator
      # quit the CLI, or it crashed. Either way the run is over and its slot
      # must be released -- run_done can no longer arrive.
      mark_process_lost!(session) unless process_alive?(session)
      session
    end

    def snapshot(session, lines: 60)
      return nil if session.pane_gone?

      Herdr.pane_read(session.herdr_pane_id, source: "recent", lines:)
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

    def mark_pane_lost!(session)
      session.update!(
        status: "failed", outcome: "failed", herdr_pane_id: nil, ended_at: Time.current,
        result: session.result.presence || "The herdr pane for this session no longer exists."
      )
      kill_process(session)
      session
    end

    def mark_process_lost!(session)
      finish!(session, outcome: "failed", result: "The session's CLI process exited without reporting a result.")
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

    def wait_until_ready!(pane_id)
      READY_POLL_ATTEMPTS.times do
        return true if Herdr.agent_get(pane_id)["interactive_ready"]

        sleep READY_POLL_INTERVAL_SECONDS
      end
      raise Error, "herdr agent in pane #{pane_id} never became ready"
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
