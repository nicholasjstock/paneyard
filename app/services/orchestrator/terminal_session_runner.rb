require "pty"
require "io/console"

module Orchestrator
  # Rails-owned lifecycle for a workspace's interactive claude/codex terminal
  # session -- the PTY analogue of Orchestrator::RunCommandRunner (detached
  # process-group tracking, exit-status-file reconciliation, SIGTERM/SIGKILL
  # stop) with two differences: the child is attached to a real pty (xterm.js
  # needs full tty semantics -- cursor control, colors, the CLIs' own
  # interactive rendering), and read/write happens live over that pty rather
  # than one-shot file redirection.
  #
  # The pty master IO can only be reattached from the OS process that opened
  # it, so REGISTRY only ever holds live sessions started by *this* Rails
  # process. config/puma.rb defaults to a single worker (WEB_CONCURRENCY
  # unset), so a single in-process registry is a safe v1 assumption -- same
  # spirit as RunCommandRunner's own accepted PID-reuse/write-scope gaps.
  # If the registry has no entry (Rails restarted, or the pty child itself
  # exited), TerminalSessionChannel falls back to #resume, which spawns a
  # fresh CLI process against the persisted cli_session_id and lets scrollback
  # replay from log_path cover what a live reattach would have shown.
  module TerminalSessionRunner
    module_function

    CLAUDE_MODEL = "sonnet"
    CODEX_MODEL = WorkerSpawner::CODEX_PROMOTED_MODEL
    READ_CHUNK_BYTES = 8_192
    STOP_GRACE_PERIOD = 2.0
    STOP_POLL_INTERVAL = 0.1

    REGISTRY = {}
    REGISTRY_MUTEX = Mutex.new

    def start(session)
      spawn_process(session, resume: false)
    end

    def resume(session)
      raise ArgumentError, "Cannot resume a session with no prior cli_session_id" if session.cli_session_id.blank?

      reap_orphan(session) unless live?(session)
      spawn_process(session, resume: true)
    end

    # A prior holder process's child can still be a live orphan (Process.spawn
    # children aren't tied to their parent's lifetime) even though this
    # process has no fd to its pty master and therefore can't reattach it.
    # Best-effort kill before spawning a replacement so two CLI processes
    # never share one cli_session_id at once.
    def reap_orphan(session)
      return if session.pid.blank? || session.process_group_id.blank?

      Process.kill("SIGTERM", -session.process_group_id) if process_alive?(session.pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # True if this process holds the live pty (and is broadcasting its
    # output) for this session. False means the caller (TerminalSessionChannel)
    # should call #resume instead -- either nothing has spawned it yet in
    # this process, or a prior holder (a since-restarted Rails process) is
    # unreachable even if its child happens to still be alive as an orphan.
    def live?(session)
      REGISTRY_MUTEX.synchronize { REGISTRY.key?(session.id) }
    end

    def write_input(session, bytes)
      entry = REGISTRY_MUTEX.synchronize { REGISTRY[session.id] }
      entry&.fetch(:writer)&.write(bytes)
    end

    def resize(session, cols:, rows:)
      cols = cols.to_i
      rows = rows.to_i
      session.update_columns(cols:, rows:)

      entry = REGISTRY_MUTEX.synchronize { REGISTRY[session.id] }
      writer = entry&.fetch(:writer)
      return unless writer

      writer.winsize = [ rows, cols ]
    rescue Errno::EIO
      nil
    end

    def reconcile!(session)
      return session if session.status == "exited"
      return session if session.pid.blank?

      if process_alive?(session.pid) && owns_process?(session)
        session.touch(:last_attached_at)
        return session
      end

      forget(session.id)
      exit_code, signal = read_exit_status(session.exit_status_path)
      session.update!(status: "exited", stopped_at: Time.current, exit_code:, signal:)
      session
    end

    def stop(session, reason: nil)
      reconcile!(session)
      return session if session.status == "exited"

      begin
        Process.kill("SIGTERM", -session.process_group_id)
      rescue Errno::ESRCH
        nil
      end

      deadline = Time.current + STOP_GRACE_PERIOD
      sleep(STOP_POLL_INTERVAL) while Time.current < deadline && owns_process?(session)

      if owns_process?(session)
        begin
          Process.kill("SIGKILL", -session.process_group_id)
        rescue Errno::ESRCH
          nil
        end
        sleep(STOP_POLL_INTERVAL)
      end

      forget(session.id)
      exit_code, signal = read_exit_status(session.exit_status_path)
      session.update!(status: "exited", stopped_at: Time.current, exit_code:, signal:)
      session
    end

    def replay(session)
      return "" unless session.log_path.present? && File.exist?(session.log_path)

      File.binread(session.log_path).dup.force_encoding("UTF-8").scrub
    end

    def spawn_process(session, resume:)
      root_dir = Pathname(session.workspace.root_path)
      policy = WorkerExecutionPolicy.new(
        root_dir:, mode: nil, write_scope: "source_protected", allowed_paths: [],
        protected_patterns: session.workspace.protected_write_patterns, profile_name: "terminal-#{session.id}"
      )

      session_dir = Rails.root.join("tmp", "terminal_sessions", session.id.to_s).to_s
      FileUtils.mkdir_p(session_dir)
      log_path = session.log_path.presence || File.join(session_dir, "session.log")
      exit_status_path = File.join(session_dir, "exit-status.txt")
      mcp_config_path = File.join(session_dir, "mcp.json")
      settings_path = File.join(session_dir, "claude-settings.json")
      File.write(log_path, "") unless resume && File.exist?(log_path)
      File.delete(exit_status_path) if File.exist?(exit_status_path)

      cli_session_id = session.cli_session_id.presence || SecureRandom.uuid
      token = TerminalSessionCapability.issue(session)
      write_mcp_config(mcp_config_path, token)
      write_claude_settings(settings_path, policy) if session.launcher_variant == "claude"

      command, args = build_args(
        session:, policy:, root_dir: root_dir.to_s, mcp_config_path:, settings_path:, cli_session_id:, resume:
      )
      env = WorkerSpawner.build_worker_env

      reader, writer, pid = spawn_pty(env:, command:, args:, chdir: root_dir.to_s, exit_status_path:)
      Process.detach(pid)

      # Applied immediately, synchronously, before the CLI has had any
      # chance to query its own terminal size at startup -- waiting on the
      # client to report its size over the wire (see the size_request
      # broadcast below) leaves a window where the CLI draws its first frame
      # assuming whatever default size PTY.spawn picked, at the wrong
      # position relative to the client's actual (already-known, larger)
      # buffer. Only meaningful on resume/restart; a truly first-ever session
      # has no persisted size yet and still needs that broadcast round-trip.
      writer.winsize = [ session.rows, session.cols ] if session.rows.present? && session.cols.present?

      session.update!(
        status: "running", pid:, process_group_id: pid, cli_session_id:, log_path:, exit_status_path:,
        started_at: Time.current, stopped_at: nil, last_attached_at: Time.current, exit_code: nil, signal: nil
      )

      register(session.id, reader, writer, log_path)

      # A fresh process always starts at whatever default pty size PTY.spawn
      # picked, regardless of what size any already-subscribed client's
      # xterm buffer is at (a data-turbo-permanent terminal element survives
      # a restart's page reload without disconnecting, so it won't
      # rediscover its own size on its own -- it only reports a size when
      # its visual box actually changes). Without this, the new CLI process
      # renders assuming the wrong screen size while the client renders into
      # its old, larger buffer -- cursor-position escape codes land in the
      # wrong place and old/new frames visibly overlap.
      ActionCable.server.broadcast(stream_name(session.id), { type: "size_request" })
      session
    rescue => error
      session.update!(status: "exited", stopped_at: Time.current) if session.persisted?
      raise error
    end

    def build_args(session:, policy:, root_dir:, mcp_config_path:, settings_path:, cli_session_id:, resume:)
      if session.launcher_variant == "claude"
        [ "claude", claude_args(policy:, root_dir:, mcp_config_path:, settings_path:, cli_session_id:, resume:) ]
      else
        [ "codex", codex_args(policy:, root_dir:, cli_session_id:, resume:) ]
      end
    end

    # NOTE: interactive (non `--print`) flag support is assumed from the
    # documented CLI surface, not exercised against a real binary here --
    # verify `--resume`/`--session-id` behavior in interactive mode manually.
    def claude_args(policy:, root_dir:, mcp_config_path:, settings_path:, cli_session_id:, resume:)
      [
        "--model", CLAUDE_MODEL,
        "--permission-mode", "dontAsk",
        "--tools", policy.claude_tools,
        "--settings", settings_path,
        "--setting-sources", "",
        "--add-dir", root_dir,
        "--mcp-config", mcp_config_path,
        "--strict-mcp-config",
        *(resume ? [ "--resume", cli_session_id ] : [ "--session-id", cli_session_id ])
      ]
    end

    # codex's interactive resumption is a distinct `codex resume <id>`
    # subcommand rather than a flag alongside a fresh session's config
    # overrides -- verify against the installed codex CLI version.
    def codex_args(policy:, root_dir:, cli_session_id:, resume:)
      config_args = policy.codex_config_overrides.flat_map { |override| [ "-c", override ] }
      return [ "resume", cli_session_id, "--model", CODEX_MODEL, "-C", root_dir ] if resume

      [ "--model", CODEX_MODEL, *config_args, "-C", root_dir ]
    end

    def write_mcp_config(path, token)
      config = {
        "mcpServers" => {
          "terminal_session" => {
            "type" => "http", "url" => "#{WorkerSpawner.rails_mcp_url}/terminal-session",
            "headers" => { "Authorization" => "Bearer #{token}" }
          }
        }
      }
      File.write(path, "#{JSON.pretty_generate(config)}\n")
      File.chmod(0o600, path)
    end

    def write_claude_settings(path, policy)
      File.write(path, "#{JSON.pretty_generate(policy.claude_settings)}\n")
      File.chmod(0o600, path)
    end

    # Wraps the CLI in the same worker_exit_wrapper shell trick WorkerSpawner/
    # RunCommandRunner use, so the exit code survives a Rails restart even
    # though Process.detach's own reaper thread doesn't. No explicit
    # `pgroup: true` here (unlike RunCommandRunner/WorkerSpawner) -- PTY.spawn
    # already makes the child a session leader of its own new process group
    # as an inherent part of allocating a controlling tty, so pid == pgid
    # already holds, and passing pgroup: true besides conflicts with that
    # (EPERM: a session leader can't also be handed a group by Process.spawn).
    def spawn_pty(env:, command:, args:, chdir:, exit_status_path:)
      PTY.spawn(
        env, "/bin/sh", "-c", WorkerSpawner.worker_exit_wrapper, "terminal-session-wrapper",
        exit_status_path, command, *args, chdir:
      )
    end

    def stream_name(session_id)
      "terminal_session_#{session_id}"
    end

    def register(session_id, reader_io, writer_io, log_path)
      reader_thread = Thread.new { pump(session_id, reader_io, log_path) }
      REGISTRY_MUTEX.synchronize { REGISTRY[session_id] = { reader: reader_io, writer: writer_io, reader_thread: } }
    end

    def forget(session_id)
      entry = REGISTRY_MUTEX.synchronize { REGISTRY.delete(session_id) }
      entry&.fetch(:reader)&.close
      entry&.fetch(:writer)&.close
    rescue IOError
      nil
    end

    # Broadcasts (rather than pushing directly to specific connections) so
    # every subscribed browser tab -- and, since solid_cable's pubsub is
    # DB-backed, any Rails process -- receives live output, even though only
    # the process that opened the pty can accept input for it (#write_input).
    #
    # A multi-byte UTF-8 character (box-drawing glyphs, etc.) can split
    # across two READ_CHUNK_BYTES reads -- write the log in raw binary (no
    # transcoding to blow up on a truncated sequence) and scrub the broadcast
    # copy so ActionCable's JSON encoding never chokes on it either; a split
    # char shows as a placeholder for one frame and self-corrects on redraw.
    def pump(session_id, reader_io, log_path)
      loop do
        chunk = reader_io.readpartial(READ_CHUNK_BYTES)
        File.write(log_path, chunk, mode: "ab")
        ActionCable.server.broadcast(stream_name(session_id), { type: "output", data: chunk.dup.force_encoding("UTF-8").scrub })
      end
    rescue EOFError, Errno::EIO, IOError
      nil
    end

    def process_alive?(pid)
      return false if pid.blank?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def owns_process?(session)
      return false unless process_alive?(session.pid)

      Process.getpgid(session.pid) == session.process_group_id
    rescue Errno::ESRCH
      false
    end

    # Shell $? for a signal-terminated child is conventionally 128+signal.
    def read_exit_status(path)
      return [ nil, nil ] unless path.present? && File.file?(path)

      value = File.read(path).strip
      return [ nil, nil ] unless value.match?(/\A\d+\z/)

      code = Integer(value, 10)
      return [ nil, code - 128 ] if code > 128 && code < 160

      [ code, nil ]
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      [ nil, nil ]
    end
  end
end
