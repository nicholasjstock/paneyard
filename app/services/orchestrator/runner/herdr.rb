require "socket"
require "timeout"

module Orchestrator
  module Runner
    # Thin JSON-RPC client for herdr (https://herdr.dev) -- the operator's own
    # already-running terminal workspace manager (their tmux replacement; see
    # ~/.config/herdr/config.toml). herdr owns every pty/process lifecycle in
    # this application; Rails only asks it to open workspaces and drive real
    # interactive claude/codex/opencode sessions inside them, so a run's actual
    # work -- tool calls, diffs, approvals -- is visible exactly as it would be
    # to someone running the CLI by hand.
    #
    # This file is deliberately free of any Rails model knowledge: it speaks
    # herdr and nothing else. Runner::SessionLauncher drives a launch through
    # it, and the run/session bookkeeping is the orchestrator's
    # (Orchestrator::RunSessionRunner), which only ever reaches it through
    # the runner (Orchestrator::Runner).
    #
    # The wire protocol (confirmed live, not inferred from the schema) is
    # newline-delimited JSON over a Unix socket: write one
    # {"id","method","params"} line, read one {"id","result"} or {"id","error"}
    # line back. Every method below was confirmed against a running server via
    # `herdr api schema --json` plus direct socket probes:
    #
    #   - workspace.create {label, cwd, env, focus} -> {root_pane: {pane_id,
    #     tab_id, workspace_id}, ...}. env is a plain string->string map applied
    #     to that pane's shell before anything is launched in it. Unlike
    #     Process.spawn's env hash it cannot express "unset this inherited var",
    #     but a brand-new pane's shell never inherited Rails' own
    #     BUNDLE_GEMFILE/RAILS_ENV/nested-Claude-Code vars in the first place, so
    #     nil-valued entries are simply dropped (see #compact_env).
    #   - agent.start {name, kind, pane_id, args} launches a real interactive CLI
    #     session in an existing pane and returns almost immediately (confirmed:
    #     0.0s, response carries launch_pending: true) -- a kickoff, not a
    #     synchronous "wait until running" call. args are typed into the pane's
    #     shell as a correctly-escaped command line (confirmed live: an
    #     adversarial arg containing $(), backticks, quotes and a literal
    #     backslash-n came back byte-identical) -- safe, but not a place to put a
    #     multi-KB prompt as a positional argv element; use agent_prompt instead.
    #   - agent.get {target: pane_id} -> {agent: {interactive_ready,
    #     agent_status, agent_session, ...}}. interactive_ready flips true once
    #     the CLI has finished its own startup and can receive input (confirmed
    #     live for Claude Code: unknown -> idle(not ready) -> idle(ready)).
    #     agent_status is idle|working|blocked|done|unknown. agent_session
    #     ({agent, kind, source, value}) carries the CLI's own session id, which
    #     is the only way to obtain a --resume id for an interactive session --
    #     unlike a --print/exec run there is no structured JSON log to parse one
    #     out of.
    #   - agent.prompt {target: pane_id, text} submits a prompt to an
    #     already-running, ready agent and returns immediately (confirmed:
    #     0.01s). text is delivered as the agent's own live input, not a shell
    #     command line, so arbitrarily large/special-character content is safe
    #     without any escaping.
    #   - pane.process_info {pane_id} -> {shell_pid,
    #     foreground_process_group_id, foreground_processes}.
    #     foreground_process_group_id equals shell_pid while a pane sits idle at
    #     its own shell prompt, and changes to the job-control process group of
    #     whatever the shell runs the moment agent.start's launch lands. Confirmed
    #     live across a full prompt/response cycle: it STAYS that new value even
    #     after the agent finishes responding, because unlike a one-shot
    #     --print/exec process a real interactive CLI never exits on its own.
    #     That group id is what Rails records as the session pid and what it must
    #     explicitly kill for "session over" to mean "process gone".
    #   - pane.split {target_pane_id, direction, ratio, cwd, env, focus} ->
    #     {pane: {pane_id, ...}}. direction is right|down; ratio is the share the
    #     split (target) pane keeps (confirmed live: 0.3 left the target 23 of 78
    #     columns). It takes no command to run: the new pane is a plain shell, so
    #     anything in it is launched with pane.send_input {pane_id, text, keys}.
    #     Confirmed live that input sent straight after the split, while the
    #     shell is still running its rc files, is held as typeahead and runs once
    #     the prompt comes up, and that workspace.close takes every pane in the
    #     workspace (and the process in it) down with it.
    #   - tab.create {workspace_id, label, cwd, env, focus} -> {tab: {tab_id,
    #     ...}, root_pane: {pane_id, ...}}. Confirmed live that focus: false in an
    #     unfocused workspace leaves both the workspace unfocused and its active
    #     tab where it was, and that workspace.close kills the processes in every
    #     tab, not just the first.
    #   - env on workspace.create / tab.create / pane.split applies to that one
    #     new pane only. Confirmed live: a split or a new tab inherits nothing
    #     from the workspace's root pane, so every pane gets exactly the env its
    #     own creating call passed (plus herdr's HERDR_* vars).
    #   - focus: true on pane.split does NOT just pick the tab's active pane: it
    #     was confirmed live to focus the whole herdr workspace and switch to that
    #     tab, taking over the operator's screen. Never pass it for a run.
    #   - pane.rename {pane_id, label} / tab.rename {tab_id, label} set the labels
    #     herdr shows (layout.export reports a pane's label back).
    #   - pane.read {pane_id, source} -> {text, truncated, ...}; source is one of
    #     visible|recent|recent_unwrapped|detection.
    #   - workspace.close {workspace_id} takes every tab and pane in the
    #     workspace down, and the processes in them.
    module Herdr
      module_function

      class Error < StandardError; end

      # A stricter signal than Error: herdr never actually answered, so nothing
      # is known about the pane/workspace in question -- unlike an error
      # *envelope* (herdr is up and told us "no such pane"), which stays a plain
      # Error. Runner::Local#agent_state relies on that distinction to avoid
      # treating a transient socket blip as proof a pane is gone -- see its
      # comment.
      class Unreachable < Error; end

      REQUEST_TIMEOUT_SECONDS = 5

      # A sandbox instance (Orchestrator::Sandbox) only ever talks to its own
      # fake herdr, whatever HERDR_SOCKET_PATH it inherited -- a run session's
      # shell has the operator's real socket in it -- unless it was started
      # with --real-herdr.
      def socket_path
        return Sandbox.herdr_socket_path if Sandbox.enabled? && !Sandbox.real_herdr?

        ENV["HERDR_SOCKET_PATH"].presence || File.expand_path("~/.config/herdr/herdr.sock")
      end

      def workspace_create(label:, cwd:, env: {}, focus: false)
        request!("workspace.create", label: Sandbox.label(label), cwd:, env: compact_env(env), focus:)
      end

      def workspace_close(workspace_id)
        request("workspace.close", workspace_id:)
      end

      def agent_start(name:, kind:, pane_id:, args:)
        request!("agent.start", name:, kind:, pane_id:, args:)
      end

      def agent_get(pane_id)
        request!("agent.get", target: pane_id).fetch("agent")
      end

      def agent_prompt(pane_id, text)
        request!("agent.prompt", target: pane_id, text:)
      end

      def agent_send_keys(pane_id, keys)
        request!("agent.send_keys", target: pane_id, keys:)
      end

      def pane_process_info(pane_id)
        request!("pane.process_info", pane_id:).fetch("process_info")
      end

      def pane_split(target_pane_id:, direction:, cwd:, focus: false, ratio: nil, env: nil)
        params = { target_pane_id:, direction:, cwd:, focus: }
        params[:ratio] = ratio if ratio
        params[:env] = compact_env(env) if env
        request!("pane.split", **params).fetch("pane")
      end

      def pane_rename(pane_id, label)
        request!("pane.rename", pane_id:, label:)
      end

      def tab_create(workspace_id:, cwd:, label: nil, env: {}, focus: false)
        request!("tab.create", workspace_id:, label:, cwd:, env: compact_env(env), focus:)
      end

      def tab_rename(tab_id, label)
        request!("tab.rename", tab_id:, label:)
      end

      def pane_send_input(pane_id, text:, keys: [])
        request!("pane.send_input", pane_id:, text:, keys:)
      end

      # pane.read nests its payload one level down, under "read" (confirmed live
      # against herdr 0.7.5, protocol 17: the result is {"type" => "pane_read",
      # "read" => {"text" => ..., ...}}), unlike agent.get's "agent" or
      # pane.process_info's "process_info" which this client reads directly. A
      # missing key is raised as a Herdr::Error rather than a KeyError so callers
      # that already rescue Herdr::Error -- Runner::Local#snapshot, whose
      # whole job is to degrade to nil rather than take the run screen down --
      # keep working.
      def pane_read(pane_id, source: "recent", lines: nil, strip_ansi: true)
        params = { pane_id:, source:, strip_ansi: }
        params[:lines] = lines if lines
        result = request!("pane.read", **params)
        text = result.dig("read", "text") || result["text"]
        raise Error, "herdr pane.read returned no text for #{pane_id}" if text.nil?

        text
      end

      # Best-effort desktop notification. A failure here must never take down
      # the caller's real work (finishing a run, publishing a PR), so unlike
      # every other method this one swallows its error.
      def notify(title:, body: nil, sound: "done")
        request("notification.show", title: Sandbox.label(title), body:, sound:)
      rescue Error
        nil
      end

      def request!(method, **params)
        response = request(method, **params)
        raise Error, response.dig("error", "message") || "herdr #{method} failed" if response.key?("error")

        response.fetch("result")
      end

      def request(method, **params)
        id = "workflow:#{method}:#{SecureRandom.hex(4)}"
        Timeout.timeout(REQUEST_TIMEOUT_SECONDS) do
          socket = UNIXSocket.new(socket_path)
          begin
            socket.write("#{JSON.generate(id:, method:, params:)}\n")
            line = socket.gets
            raise Unreachable, "herdr socket closed without a response for #{method}" if line.nil?

            JSON.parse(line)
          ensure
            socket.close
          end
        end
      rescue Errno::ENOENT, Errno::ECONNREFUSED => e
        raise Unreachable, "herdr is not running (#{e.message})"
      rescue Timeout::Error
        raise Unreachable, "herdr #{method} timed out after #{REQUEST_TIMEOUT_SECONDS}s"
      rescue JSON::ParserError => e
        raise Unreachable, "herdr sent an unparseable response to #{method}: #{e.message}"
      end

      # herdr's env map has no "unset this variable" representation, and every
      # value must be a string. Callers build env hashes in Process.spawn's
      # shape (where a nil value means "remove it from the child"), so drop
      # those entries rather than sending "" -- see this module's header for why
      # that is safe for a freshly created pane.
      def compact_env(env)
        env.compact.transform_values(&:to_s)
      end
    end
  end
end
