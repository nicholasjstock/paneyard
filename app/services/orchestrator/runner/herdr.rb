require "socket"
require "timeout"

module Orchestrator
  module Runner
    # Thin JSON-RPC client for herdr (https://herdr.dev) -- the operator's own
    # already-running terminal workspace manager (their tmux replacement; see
    # ~/.config/herdr/config.toml). herdr owns every pty/process lifecycle in
    # this application; Rails only asks it to open workspaces and drive real
    # interactive claude/codex sessions inside them, so a run's actual
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
    #     already-running, ready agent. text is delivered as the agent's own
    #     live input, not a shell command line, so arbitrarily
    #     large/special-character content is safe without any escaping. It was
    #     confirmed to return in 0.01s on an idle herdr, but it answers only
    #     once the text is delivered, so its time grows with the prompt and
    #     with whatever else herdr is doing: run-20261004-132411-8668 (a ~5KB
    #     prompt, launched beside other runs' worktree.open) took over 5s, with
    #     the text still arriving in the pane. Hence its own, longer timeout
    #     (AGENT_PROMPT_TIMEOUT_SECONDS).
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
    #   - pane.split {target_pane_id, direction, ratio, cwd, focus} ->
    #     {pane: {pane_id, ...}}. direction is right|down; ratio is the share the
    #     split (target) pane keeps (confirmed live: 0.3 left the target 23 of 78
    #     columns). It takes no command to run: the new pane is a plain shell, so
    #     anything in it is launched with pane.send_input {pane_id, text, keys}.
    #     Confirmed live that input sent straight after the split, while the
    #     shell is still running its rc files, is held as typeahead and runs once
    #     the prompt comes up, and that workspace.close takes every pane in the
    #     workspace (and the process in it) down with it.
    #   - tab.create {workspace_id, label, cwd, focus} -> {tab: {tab_id,
    #     ...}, root_pane: {pane_id, ...}}. Confirmed live that focus: false in an
    #     unfocused workspace leaves both the workspace unfocused and its active
    #     tab where it was, and that workspace.close kills the processes in every
    #     tab, not just the first.
    #   - Paneyard passes no env to any pane. herdr's env on tab.create and
    #     pane.split applies to that one new pane, a pane inherits nothing from
    #     another, and worktree.create (which makes the agent's pane) takes none,
    #     so every pane is the operator's own login shell. A session's identity
    #     travels in its CLI's arguments and config files instead
    #     (Runner::SessionArgs).
    #   - focus: true on pane.split does NOT just pick the tab's active pane: it
    #     was confirmed live to focus the whole herdr workspace and switch to that
    #     tab, taking over the operator's screen. Never pass it for a run.
    #   - pane.rename {pane_id, label} / tab.rename {tab_id, label} set the labels
    #     herdr shows (layout.export reports a pane's label back).
    #   - pane.read {pane_id, source} -> {text, truncated, ...}; source is one of
    #     visible|recent|recent_unwrapped|detection.
    #   - workspace.close {workspace_id} takes every tab and pane in the
    #     workspace down, and the processes in them.
    #   - worktree.create {cwd, branch, base, label, focus} (herdr 0.7.5) makes
    #     a linked git worktree of the repository at cwd, wherever the
    #     operator's herdr config puts worktrees (~/.herdr/worktrees/<repo>/
    #     <branch> by default; never given a path here), and opens it as a herdr
    #     workspace. Returns {workspace, tab, root_pane, worktree: {path,
    #     branch, ...}}. A new branch is created from `base` (any ref; confirmed
    #     live that a branch other than the one checked out at cwd works), an
    #     existing one is checked out as is at its own commit, with or without
    #     a `base` (which it then ignores; confirmed live), at the same path a
    #     new one of that name would get. It also opens a primary workspace
    #     for the repository itself if none is open. It takes no env, so the
    #     root pane's shell is the operator's login shell and nothing more.
    #   - worktree.open {cwd, path, focus} returns the worktree's open workspace,
    #     opening one if it is closed (already_open says which).
    #   - worktree.remove {workspace_id, force} runs `git worktree remove` for
    #     a linked worktree's *open* workspace (a closed one is
    #     workspace_not_found: open it first) and closes that workspace. It never
    #     deletes the branch, refuses a dirty worktree with
    #     dirty_worktree_requires_force unless forced, and refuses a primary
    #     checkout outright (not_linked_worktree).
    #   - tab.close {tab_id}.
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

      # herdr accepted the connection but did not answer within the request's
      # timeout. Still Unreachable to every caller that only cares that
      # nothing is known, but a caller that does care can tell it apart from
      # herdr not running at all: a slow agent.prompt may well have delivered
      # its text (see Runner::SessionLauncher#deliver_prompt).
      class TimedOut < Unreachable; end

      # Every request but agent.prompt is a quick lookup or a kickoff that
      # herdr answers in milliseconds.
      REQUEST_TIMEOUT_SECONDS = 5
      # agent.prompt answers only once its text is delivered, which takes
      # longer the larger the prompt and the busier herdr is. A fixed 30s
      # rather than one scaled by size: the run that hit the 5s limit had a
      # ~5KB prompt while a 5.1KB one launched fine beside it, so size alone
      # does not predict it, and a timeout here no longer fails the launch
      # anyway -- SessionLauncher then watches whether the agent picked the
      # prompt up. 30s is six times the slowest reply seen, and keeps a
      # launch stuck on it well inside StartRunSessionJob's other waits.
      AGENT_PROMPT_TIMEOUT_SECONDS = 30

      # A sandbox instance (Orchestrator::Sandbox) only ever talks to its own
      # fake herdr, whatever HERDR_SOCKET_PATH it inherited -- a run session's
      # shell has the operator's real socket in it -- unless it was started
      # with --real-herdr.
      def socket_path
        return Sandbox.herdr_socket_path if Sandbox.enabled? && !Sandbox.real_herdr?

        ENV["HERDR_SOCKET_PATH"].presence || File.expand_path("~/.config/herdr/herdr.sock")
      end

      def workspace_close(workspace_id)
        request("workspace.close", workspace_id:)
      end

      def workspace_close!(workspace_id)
        response = workspace_close(workspace_id)
        error = response["error"]
        return if error.nil? || error["code"] == "workspace_not_found"

        raise Error, error["message"] || "herdr could not close workspace"
      end

      def worktree_create(cwd:, branch:, base:, label:, focus: false)
        request!("worktree.create", cwd:, branch:, base:, label: Sandbox.label(label), focus:)
      end

      def worktree_open(cwd:, path:, label: nil, focus: false)
        params = { cwd:, path:, focus: }
        params[:label] = Sandbox.label(label) if label
        request!("worktree.open", **params)
      end

      def worktree_remove(workspace_id, force: false)
        request!("worktree.remove", workspace_id:, force:)
      end

      def agent_start(name:, kind:, pane_id:, args:)
        request!("agent.start", name:, kind:, pane_id:, args:)
      end

      def agent_get(pane_id)
        request!("agent.get", target: pane_id).fetch("agent")
      end

      def agent_prompt(pane_id, text)
        request!("agent.prompt", timeout: AGENT_PROMPT_TIMEOUT_SECONDS, target: pane_id, text:)
      end

      def agent_send_keys(pane_id, keys)
        request!("agent.send_keys", target: pane_id, keys:)
      end

      def pane_process_info(pane_id)
        request!("pane.process_info", pane_id:).fetch("process_info")
      end

      def pane_split(target_pane_id:, direction:, cwd:, focus: false, ratio: nil)
        params = { target_pane_id:, direction:, cwd:, focus: }
        params[:ratio] = ratio if ratio
        request!("pane.split", **params).fetch("pane")
      end

      def pane_list(workspace_id:)
        request!("pane.list", workspace_id:).fetch("panes")
      end

      def pane_rename(pane_id, label)
        request!("pane.rename", pane_id:, label:)
      end

      def tab_create(workspace_id:, cwd:, label: nil, focus: false)
        request!("tab.create", workspace_id:, label:, cwd:, focus:)
      end

      def tab_close(tab_id)
        request!("tab.close", tab_id:)
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
      # whole job is to degrade to nil rather than break a run-status read --
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

      def request!(method, timeout: REQUEST_TIMEOUT_SECONDS, **params)
        response = request(method, timeout:, **params)
        raise Error, response.dig("error", "message") || "herdr #{method} failed" if response.key?("error")

        response.fetch("result")
      end

      # `timeout` (seconds) bounds the whole request, from connecting to the
      # response line; it is not sent to herdr.
      def request(method, timeout: REQUEST_TIMEOUT_SECONDS, **params)
        id = "paneyard:#{method}:#{SecureRandom.hex(4)}"
        Timeout.timeout(timeout) do
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
        raise TimedOut, "herdr #{method} timed out after #{timeout}s"
      rescue JSON::ParserError => e
        raise Unreachable, "herdr sent an unparseable response to #{method}: #{e.message}"
      end
    end
  end
end
