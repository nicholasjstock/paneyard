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
      # See submit_prompt_if_unsent!: each window is always sampled whole, and
      # the prompt counts as picked up only if the agent was non-idle on each
      # of its last PROMPT_SUBMIT_STABLE_SAMPLES samples.
      PROMPT_SUBMIT_POLL_ATTEMPTS = 20
      PROMPT_SUBMIT_POLL_INTERVAL_SECONDS = 0.5
      PROMPT_SUBMIT_STABLE_SAMPLES = 4
      # The window watched after each Enter, in samples (x 0.5 s = 3, 5, 7, 10,
      # 15 and 20 s): so Enters go out about 10, 13, 18, 25, 35 and 50 s after
      # agent.prompt, and a launch gives up about 70 s after it. Why those
      # numbers is in submit_prompt_if_unsent!'s comment.
      PROMPT_SUBMIT_RETRY_WINDOWS = [ 6, 10, 14, 20, 30, 40 ].freeze

      # Writes the files the CLI reads (its MCP config for claude, and the
      # prompt, kept for the record) and builds the layout in the herdr
      # workspace herdr opened for the run's worktree. Returns
      # { "workspace_id", "tab_id", "pane_id", "mcp_config_path",
      # "prompt_path" }, the pane ids being the agent's.
      def open(spec, runtime_root:)
        runtime_dir = File.join(runtime_root.to_s, Attachments.sanitize_run_id(spec.fetch(:run_id)))
        FileUtils.mkdir_p(runtime_dir)
        mcp_config_path = File.join(runtime_dir, "mcp.json")
        if spec.fetch(:driver) == "claude"
          SessionArgs.write_claude_mcp_config(mcp_config_path, spec.fetch(:capability_token), mcp_url: spec.fetch(:mcp_url))
        end

        prompt_path = File.join(runtime_dir, "prompt.txt")
        File.write(prompt_path, spec.fetch(:prompt))

        # Only the agent pane is recorded -- see SessionLayout.
        root_pane = {
          "workspace_id" => spec.fetch(:herdr_workspace_id), "tab_id" => spec.fetch(:herdr_tab_id),
          "pane_id" => spec.fetch(:herdr_pane_id)
        }
        agent_pane = SessionLayout.open!(root_pane:, cwd: spec.fetch(:cwd), tabs: spec.fetch(:layout))
        agent_pane.slice("workspace_id", "tab_id", "pane_id").merge("mcp_config_path" => mcp_config_path, "prompt_path" => prompt_path)
      end

      # Starts the agent in the pane #open returned and submits the prompt.
      # Returns its pid, or raises LaunchError.
      def launch(spec, pane_id:, mcp_config_path:)
        kind, args = command(spec, mcp_config_path)
        trust_claude_folder!(spec.fetch(:cwd)) if spec.fetch(:driver) == "claude"
        start_agent!(name: spec.fetch(:run_id), kind:, pane_id:, args:)
        wait_for_agent_detected!(pane_id, kind:)
        dismiss_codex_trust_prompt!(pane_id) if spec.fetch(:driver) == "codex"
        wait_until_ready!(pane_id, kind:)
        prompt = deliver_prompt(pane_id, spec.fetch(:prompt), run_id: spec.fetch(:run_id))
        submit_prompt_if_unsent!(pane_id, run_id: spec.fetch(:run_id), prompt:)

        wait_for_pid(pane_id) || raise(LaunchError, "session for run #{spec.fetch(:run_id)} never started a foreground process")
      end

      # A config problem should not mask the launch. If trust could not be
      # recorded, the normal launch diagnostics will show Claude's prompt.
      def trust_claude_folder!(dir)
        ClaudeTrust.trust!(dir)
      rescue StandardError => error
        Rails.logger.warn("[SessionLauncher] could not mark #{dir} as trusted for claude: #{error.message}")
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
      #
      # codex can be detected and then exit inside the grace period -- confirmed
      # live: `codex resume <id>` for a conversation it does not have prints
      # "No saved session found with ID ..." and quits -- so herdr answering the
      # Enter with "agent target ... not found" means codex never started.
      def dismiss_codex_trust_prompt!(pane_id)
        sleep CODEX_TRUST_PROMPT_GRACE_SECONDS
        Herdr.agent_send_keys(pane_id, [ "Enter" ])
      rescue Herdr::Unreachable
        raise
      rescue Herdr::Error => error
        raise unless error.message.match?(/agent target .* not found/)

        raise LaunchError, "codex exited in pane #{pane_id} before it was ready (herdr: #{error.message})"
      end

      # worktree.create returns a pane whose shell exists immediately, but that
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

      # Sends the prompt, once. Returns { seconds:, timed_out: } for
      # submit_prompt_if_unsent!, which logs it with its verdict.
      #
      # herdr answering agent.prompt late is not evidence that the text was
      # lost: on run-20261004-132411-8668 the 5s request timeout fired while
      # the prompt was still arriving in claude's input box, and failing the
      # launch then tore down a session that had its task. So a timeout
      # (Herdr::TimedOut) is no verdict here; submit_prompt_if_unsent! decides
      # from what the agent does next, and the launch fails only if it never
      # showed any sign of the prompt. agent.prompt itself is never sent
      # again: the first one may have been delivered, and a second would type
      # the whole task into the agent twice. herdr not running at all
      # (Herdr::Unreachable for a missing or refused socket) still fails the
      # launch at once.
      def deliver_prompt(pane_id, text, run_id:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        seconds = -> { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) }
        Herdr.agent_prompt(pane_id, text)
        { seconds: seconds.call, timed_out: false }
      rescue Herdr::TimedOut => error
        Rails.logger.warn("[SessionLauncher] run #{run_id} pane #{pane_id}: #{error.message} (#{text.bytesize}-byte prompt); " \
                          "not resending it, since herdr may have delivered it -- watching whether the agent picks it up")
        { seconds: seconds.call, timed_out: true }
      end

      # agent.prompt normally submits on its own -- confirmed live, including
      # with this app's real ~5KB composed prompt. But it has also been seen on
      # real runs to deliver the text and leave it sitting unsubmitted in
      # Claude's input box: the session stayed idle forever, holding its
      # concurrency slot, and a single Enter submitted it. That was not
      # reproducible in isolation, so rather than always send an Enter, check
      # whether the agent actually picked the prompt up and nudge it if not.
      #
      # This used to take the first non-idle agent_status as "submitted" and
      # return at once. Run run-20260929-191533-d44e (claude, ~3KB prompt) was
      # left unsubmitted all the same: most likely herdr briefly reported the
      # agent non-idle while the text was being pasted and rendered, then
      # dropped back to idle, and the one sample settled it. So now the whole
      # window is sampled, and only an agent that was non-idle on each of the
      # last PROMPT_SUBMIT_STABLE_SAMPLES samples counts as working; a
      # herdr error is no evidence either way, so it breaks that streak too.
      #
      # One Enter was then not always enough. On run-20260929-194456-3ec1
      # (claude, ~4.4KB prompt) the agent sat idle for the whole 10 s window,
      # the Enter went out at +10 s and herdr accepted it -- and nothing was
      # submitted. The operator's own Enter in the pane at about +84 s was, and
      # on an earlier stuck run an Enter sent about 2 minutes after the prompt
      # was too. The received text was the prompt exactly, so no Enter had
      # landed mid-text. Unconfirmed hypothesis: Claude drops or absorbs an
      # Enter that arrives too soon after a large typed or pasted input, or too
      # soon after its own startup, and a later one works.
      #
      # So after each Enter the next window (PROMPT_SUBMIT_RETRY_WINDOWS) is
      # sampled the same way, and while the agent is still not picked up
      # another Enter goes out, up to six in all, at about +10, 13, 18, 25, 35
      # and 50 s. The threshold, if there is one, lies somewhere between the
      # 10 s that failed and the 84 s that worked: the early Enters are close
      # together in case being a few seconds late is enough, and the spacing
      # then widens to reach past a minute in few attempts. The last window
      # ends about 70 s after agent.prompt, so a stuck launch holds
      # StartRunSessionJob about a minute longer than a healthy one and never
      # more: after that the launch goes ahead (the pid is read, the run is
      # running) with a warning in the log and a herdr notification, and the
      # operator can still press Enter in the pane -- failing the run would
      # only throw away a session one keystroke from working.
      #
      # An Enter on an already-submitted (empty) input box does nothing, so a
      # spurious one is cheap, while a missed one strands the run: lean towards
      # sending it. One case is excluded from the retries, though: an agent
      # that was non-idle for PROMPT_SUBMIT_STABLE_SAMPLES samples in a row at
      # any point has evidently taken on work, far longer than the paste blip
      # above, and is idle again only because it finished (a fast task, or the
      # fake agent in specs and bin/sandbox). It still gets the first Enter, as
      # before, but not a minute of retries holding its launch open.
      #
      # The pane text itself is not used as a second "still unsent" signal.
      # Every driver echoes a submitted prompt into its transcript, so the
      # prompt's last line stays visible in the pane after it was submitted
      # just as before; claude folds a long paste into a "[Pasted text ...]"
      # placeholder; and all three wrap and truncate it to the pane width. And
      # since an idle agent gets its Enter anyway, the only verdict such a
      # signal could change is "picked up", which is exactly where the echo
      # would make it wrong.
      #
      # Every Enter is logged with the time since agent.prompt and the samples
      # so far, so the next occurrence shows how late an Enter had to be to
      # work, and the verdict with how long agent.prompt itself took (`prompt`,
      # from deliver_prompt). Returns true if no Enter was needed.
      #
      # When agent.prompt timed out, there is one more verdict: an agent that
      # was never once seen non-idle, through every window and Enter, most
      # likely never got its task, and the launch fails (LaunchError) with
      # what was observed. Any activity at all -- even the brief blip of text
      # arriving -- means the text is probably in its input box, which is the
      # stranded-prompt case above, and the launch goes ahead as it does there.
      def submit_prompt_if_unsent!(pane_id, run_id:, prompt: nil)
        prompt_note = prompt_timing(prompt)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = -> { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) }
        history = []
        window = sample_prompt_status(pane_id, PROMPT_SUBMIT_POLL_ATTEMPTS, first_sleep: false)
        history.concat(window)
        enters = 0

        loop do
          if prompt_picked_up?(window)
            Rails.logger.info("[SessionLauncher] run #{run_id} pane #{pane_id}: prompt picked up #{elapsed.call}s after " \
                              "agent.prompt#{prompt_note}, after #{enters} Enter(s) (agent_status: #{summarize_samples(history)})")
            return enters.zero?
          end
          break if enters >= PROMPT_SUBMIT_RETRY_WINDOWS.size
          if enters.positive? && sustained_work?(history)
            Rails.logger.info("[SessionLauncher] run #{run_id} pane #{pane_id}: agent was seen working and is idle again " \
                              "#{elapsed.call}s after agent.prompt#{prompt_note}; no more Enters (agent_status: #{summarize_samples(history)})")
            return false
          end

          enters += 1
          Rails.logger.warn("[SessionLauncher] run #{run_id} pane #{pane_id}: prompt not seen picked up #{elapsed.call}s after " \
                            "agent.prompt (agent_status: #{summarize_samples(history)}); sending Enter " \
                            "#{enters}/#{PROMPT_SUBMIT_RETRY_WINDOWS.size} to submit it")
          history << send_prompt_enter(pane_id, run_id:)
          window = sample_prompt_status(pane_id, PROMPT_SUBMIT_RETRY_WINDOWS[enters - 1])
          history.concat(window)
        end

        if prompt&.fetch(:timed_out) && history.none? { |status| agent_busy?(status) }
          raise LaunchError, "herdr agent.prompt gave no reply within #{prompt.fetch(:seconds)}s, and the agent in pane " \
                             "#{pane_id} then was never seen busy in #{elapsed.call}s of watching, through #{enters} Enters " \
                             "(agent_status: #{summarize_samples(history)}): its task most likely never arrived"
        end

        Rails.logger.warn("[SessionLauncher] run #{run_id} pane #{pane_id}: prompt still not seen picked up #{elapsed.call}s " \
                          "after agent.prompt#{prompt_note} and #{enters} Enters (agent_status: #{summarize_samples(history)}); " \
                          "leaving the session running -- its task may be sitting unsent in the pane's input box")
        Herdr.notify(title: "Run #{run_id}: prompt may be unsent",
                     body: "#{enters} Enters did not submit it; press Enter in pane #{pane_id}", sound: "request")
        false
      end

      # " (which took 0.4s)", " (which timed out after 30.1s)", or "".
      def prompt_timing(prompt)
        return "" unless prompt

        prompt.fetch(:timed_out) ? " (which timed out after #{prompt.fetch(:seconds)}s)" : " (which took #{prompt.fetch(:seconds)}s)"
      end

      def sample_prompt_status(pane_id, count, first_sleep: true)
        Array.new(count) do |index|
          sleep PROMPT_SUBMIT_POLL_INTERVAL_SECONDS if first_sleep || !index.zero?
          prompt_status_sample(pane_id)
        end
      end

      def prompt_picked_up?(window)
        tail = window.last(PROMPT_SUBMIT_STABLE_SAMPLES)
        tail.size == PROMPT_SUBMIT_STABLE_SAMPLES && tail.all? { |status| agent_busy?(status) }
      end

      def sustained_work?(history)
        history.chunk_while { |a, b| agent_busy?(a) && agent_busy?(b) }
               .any? { |run| run.size >= PROMPT_SUBMIT_STABLE_SAMPLES && agent_busy?(run.first) }
      end

      # Enter markers in the history ("ENTER") are neither.
      def agent_busy?(status)
        !(status == "idle" || status.start_with?("ENTER", "error"))
      end

      # Returns the marker the history records for it. A failed Enter is logged
      # and counted like any other: the retries are bounded either way, and the
      # launch should not fail over a keystroke.
      def send_prompt_enter(pane_id, run_id:)
        Herdr.agent_send_keys(pane_id, [ "Enter" ])
        "ENTER"
      rescue Herdr::Error => error
        Rails.logger.warn("[SessionLauncher] run #{run_id} pane #{pane_id}: sending Enter failed: #{error.message}")
        "ENTER(failed)"
      end

      def prompt_status_sample(pane_id)
        Herdr.agent_get(pane_id)["agent_status"].to_s.presence || "unknown"
      rescue Herdr::Error => error
        "error(#{error.class.name.demodulize})"
      end

      # ["idle", "working", "working", "idle"] -> "idle, working x2, idle"
      def summarize_samples(samples)
        samples.chunk_while { |a, b| a == b }.map { |run| run.size > 1 ? "#{run.first} x#{run.size}" : run.first }.join(", ")
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
