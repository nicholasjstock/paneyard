require "fileutils"

module Orchestrator
  module Runner
    # Opens a run's session on this machine and brings its agent up: the
    # runtime files the CLI reads, the herdr workspace from the run's layout,
    # then the launch itself -- waiting out the pane's shell startup, starting
    # the CLI, waiting for herdr to see it and for it to become ready,
    # submitting the prompt, and reading back the process group that is the
    # session's pid.
    #
    # Everything here is keyed by the plain session spec the orchestrator
    # builds (Orchestrator::RunSessionRunner.session_spec) and returns plain
    # data; what those results mean for the run is the orchestrator's
    # business. The two halves are separate calls so the orchestrator can
    # record the panes before the launch, which is what lets a failed or
    # abandoned launch still be read and closed.
    module SessionLauncher
      module_function

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
      PROMPT_SUBMIT_POLL_ATTEMPTS = 8
      PROMPT_SUBMIT_POLL_INTERVAL_SECONDS = 0.5

      # Writes the files the CLI reads (its MCP config for claude, and the
      # prompt, kept for the record), builds the session env and opens the
      # layout. Returns { "workspace_id", "tab_id", "pane_id",
      # "mcp_config_path", "prompt_path" }, the pane ids being the agent's.
      def open(spec, runtime_root:)
        runtime_dir = File.join(runtime_root.to_s, Attachments.sanitize_run_id(spec.fetch(:run_id)))
        FileUtils.mkdir_p(runtime_dir)
        mcp_config_path = File.join(runtime_dir, "mcp.json")
        if spec.fetch(:driver) == "claude"
          SessionArgs.write_claude_mcp_config(mcp_config_path, spec.fetch(:capability_token), mcp_url: spec.fetch(:mcp_url))
        end

        _kind, _args, extra_env = command(spec, mcp_config_path)
        env = ProcessEnv.for_session(
          workspace_env: spec.fetch(:workspace_env), env: spec.fetch(:env),
          capability_token: spec.fetch(:capability_token), github_token: spec[:github_token],
          ambient_github_auth: spec.fetch(:ambient_github_auth), extra: extra_env
        )

        prompt_path = File.join(runtime_dir, "prompt.txt")
        File.write(prompt_path, spec.fetch(:prompt))

        # Only the agent pane is recorded -- see SessionLayout.
        root_pane = SessionLayout.open!(label: spec.fetch(:label), cwd: spec.fetch(:cwd), env:, tabs: spec.fetch(:layout))
        root_pane.slice("workspace_id", "tab_id", "pane_id").merge("mcp_config_path" => mcp_config_path, "prompt_path" => prompt_path)
      end

      # Starts the agent in the pane #open returned and submits the prompt.
      # Returns its pid, or raises LaunchError.
      def launch(spec, pane_id:, mcp_config_path:)
        kind, args, _extra_env = command(spec, mcp_config_path)
        start_agent!(name: spec.fetch(:run_id), kind:, pane_id:, args:)
        wait_for_agent_detected!(pane_id, kind:)
        dismiss_codex_trust_prompt!(pane_id) if spec.fetch(:driver) == "codex"
        wait_until_ready!(pane_id, kind:)
        Herdr.agent_prompt(pane_id, spec.fetch(:prompt))
        submit_prompt_if_unsent!(pane_id)

        wait_for_pid(pane_id) || raise(LaunchError, "session for run #{spec.fetch(:run_id)} never started a foreground process")
      end

      def command(spec, mcp_config_path)
        SessionArgs.build(
          driver: spec.fetch(:driver), root_dir: spec.fetch(:cwd), mcp_config_path:,
          capability_token: spec.fetch(:capability_token), mcp_url: spec.fetch(:mcp_url),
          model: spec.fetch(:model), resume_session_id: spec[:resume_session_id]
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
        raise LaunchError, "pane #{pane_id} never settled at an idle shell prompt"
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
      # Orchestrator::RunSessionRunner.refresh!) would fail identically a second time.
      def wait_for_agent_detected!(pane_id, kind:)
        AGENT_DETECT_POLL_ATTEMPTS.times do
          return true if agent_info!(pane_id, kind:, waiting_for: "start")["agent"].present?

          sleep AGENT_DETECT_POLL_INTERVAL_SECONDS
        end
        seconds = (AGENT_DETECT_POLL_ATTEMPTS * AGENT_DETECT_POLL_INTERVAL_SECONDS).round
        raise LaunchError, "herdr never detected #{kind} starting in pane #{pane_id} after #{seconds}s: " \
                     "the command line was typed into the pane's shell, but no #{kind} process appeared"
      end

      def wait_until_ready!(pane_id, kind:)
        READY_POLL_ATTEMPTS.times do
          return true if agent_info!(pane_id, kind:, waiting_for: "become ready")["interactive_ready"]

          sleep READY_POLL_INTERVAL_SECONDS
        end
        raise LaunchError, "herdr agent in pane #{pane_id} never became ready"
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

        raise LaunchError, "herdr stopped tracking the #{kind} launch in pane #{pane_id} while waiting for it to " \
                     "#{waiting_for} (herdr: #{error.message}); herdr drops an agent.start it has not " \
                     "seen become ready within its startup timeout, so #{kind} most likely never started or exited"
      end

      # A pane's foreground_process_group_id equals its shell_pid while it sits
      # idle at its own prompt, and changes to the job-control process group of
      # whatever the shell runs the moment agent.start's launch lands. That
      # group id is the session's pid, and matches Runner::Local#terminate's `kill -pid`
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
    end
  end
end
