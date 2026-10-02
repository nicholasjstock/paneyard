require "digest"
require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require "socket"
require "time"

module PaneyardPlugin
  # The plugin's one long-running process: this checkout's bin/production
  # (Puma + Solid Queue, db:prepare on every start), detached in its own
  # process group, with every piece of state under the plugin's state
  # directory -- the bin/service of a herdr install.
  #
  # herdr's [[startup]] hook is one-shot and is not run on install or link,
  # so every action calls #ensure_running too. That has to be cheap when the
  # daemon is up and safe when several callers race, hence the flock around
  # everything that starts or stops it.
  #
  # One daemon per user: daemon.json records the herdr socket it was started
  # for, and a caller from a different herdr server leaves it alone (its
  # sessions live on the first server, and reconcile would count them lost).
  class Daemon
    STARTUP_TIMEOUT = 120
    STOP_GRACE = 15
    POLL_INTERVAL = 0.2
    LOG_ROTATE_BYTES = 10 * 1024 * 1024

    # What the daemon must not inherit from whoever started it: another
    # bundle's activation, another Rails app's environment, a sandbox's or a
    # run session's identity. Everything the plugin owns is set afresh.
    INHERITED_KEYS_TO_DROP = %w[
      RUBYOPT RUBYLIB GEM_HOME GEM_PATH RAILS_ENV RACK_ENV PORT PIDFILE
      PANEYARD_SANDBOX PANEYARD_SANDBOX_ROOT PANEYARD_SANDBOX_REAL_HERDR
      PANEYARD_RUN_ID PANEYARD_RUN_TOKEN SECRET_KEY_BASE RAILS_MASTER_KEY
    ].freeze

    Result = Struct.new(:outcome, :pid, :port, :url, :herdr_socket, :previous_port, keyword_init: true) do
      # :running, :started, :restarted, or :elsewhere (up, but for another herdr server).
      def started? = %i[started restarted].include?(outcome)
      def port_changed? = !previous_port.nil? && previous_port != port
    end

    attr_reader :paths

    # `command` replaces bin/production (specs run a stand-in that answers /up).
    def initialize(paths:, ruby: RbConfig.ruby, herdr_socket: ENV["HERDR_SOCKET_PATH"], env: ENV, command: nil,
      startup_timeout: STARTUP_TIMEOUT, stop_grace: STOP_GRACE)
      @paths = paths
      @ruby = ruby
      @herdr_socket = herdr_socket.to_s.strip.empty? ? nil : herdr_socket
      @base_env = env.to_h
      @command = command || [ ruby, File.join(paths.app_root, "bin", "production") ]
      @startup_timeout = startup_timeout
      @stop_grace = stop_grace
    end

    # The running daemon's recorded state, or nil when there is none.
    def status
      state = live_state
      state && result(:running, state)
    end

    def ensure_running
      locked do
        state = live_state
        next result(:started, start_locked) unless state

        recorded_socket = state["herdr_socket"]
        next result(:elsewhere, state) if @herdr_socket && recorded_socket && recorded_socket != @herdr_socket

        if state["fingerprint"] != fingerprint
          stop_locked(state)
          next result(:restarted, start_locked, previous_port: state["port"])
        end

        wait_until_up!(state["pid"], state["port"])
        result(:running, state)
      end
    end

    def restart
      locked do
        state = live_state
        stop_locked(state) if state
        result(state ? :restarted : :started, start_locked, previous_port: state && state["port"])
      end
    end

    # Returns whether a daemon was running.
    def stop
      locked do
        state = live_state
        stop_locked(state) if state
        FileUtils.rm_f(paths.daemon_file)
        !state.nil?
      end
    end

    # What the daemon would run, so a change to any of it (a reinstall, a new
    # bundle, an edited .env) restarts it on the next action.
    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate([
        manifest_version, paths.app_root, @ruby, @command,
        read_if_exists(File.join(paths.app_root, "Gemfile.lock")),
        read_if_exists(paths.env_file)
      ]))
    end

    def manifest_version
      read_if_exists(paths.manifest_file).to_s[/^version\s*=\s*"([^"]+)"/, 1]
    end

    # The whole environment bin/production runs with: the caller's (herdr's
    # server environment, for a plugin command) less what it must not
    # inherit, then the operator's .env, then what the plugin decides.
    def daemon_env(port)
      settings, = EnvFile.load(paths.env_file)
      url = "http://127.0.0.1:#{port}"
      @base_env.reject { |key, _| key.start_with?("BUNDLE_", "BUNDLER_") || INHERITED_KEYS_TO_DROP.include?(key) }
        .merge(settings.except("PORT"))
        .merge(
          "RAILS_ENV" => "production",
          "PORT" => port.to_s,
          "BINDING" => "127.0.0.1",
          "PANEYARD_RAILS_URL" => url,
          "PANEYARD_STORAGE_DIR" => paths.storage_dir,
          "PANEYARD_RUNTIME_DIR" => paths.runtime_dir,
          "PIDFILE" => paths.puma_pid_file,
          "HERDR_SOCKET_PATH" => @herdr_socket,
          # bin/production's `bundle` and `./bin/rails` (#!/usr/bin/env ruby)
          # must find the Ruby the gems were built for. herdr panes never
          # inherit this, so sessions keep the operator's own PATH.
          "PATH" => [ File.dirname(@ruby), @base_env["PATH"] ].compact.join(File::PATH_SEPARATOR)
        )
        .merge("SECRET_KEY_BASE" => settings["SECRET_KEY_BASE"] || Secrets.secret_key_base(paths.secret_file))
        .compact
    end

    private

    # A port change is news only from the start that made it.
    def result(outcome, state, previous_port: nil)
      previous_port ||= state["previous_port"] if %i[started restarted].include?(outcome)
      Result.new(outcome:, pid: state["pid"], port: state["port"], url: state["url"], herdr_socket: state["herdr_socket"],
        previous_port:)
    end

    def locked
      FileUtils.mkdir_p(paths.state_dir)
      File.open(paths.lock_file, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def start_locked
      FileUtils.mkdir_p([ paths.storage_dir, paths.runtime_dir, paths.log_dir ])
      EnvFile.write_sample(paths.env_file)
      port, previous_port = choose_port
      env = daemon_env(port)
      rotate_log
      log = File.open(paths.log_file, "a")
      log.puts("--- #{Time.now.iso8601} paneyard plugin #{manifest_version}: starting #{@command.join(' ')} on port #{port}")
      log.flush

      pid = Process.spawn(env, *@command, chdir: paths.app_root, pgroup: true, unsetenv_others: true,
        in: File::NULL, out: log, err: log)
      Process.detach(pid)
      log.close
      state = {
        "pid" => pid, "identity" => identity(pid), "port" => port, "url" => "http://127.0.0.1:#{port}",
        "herdr_socket" => @herdr_socket, "fingerprint" => fingerprint, "previous_port" => previous_port,
        "app_root" => paths.app_root, "ruby" => @ruby, "started_at" => Time.now.iso8601
      }
      write(paths.daemon_file, JSON.pretty_generate(state))
      write(paths.port_file, port.to_s)
      write(paths.url_file, state["url"])

      begin
        wait_until_up!(pid, port)
      rescue Error
        signal_group(pid, "KILL")
        FileUtils.rm_f(paths.daemon_file)
        raise
      end
      state
    end

    def stop_locked(state)
      pid = state["pid"]
      signal_group(pid, "TERM")
      deadline = Time.now + @stop_grace
      sleep POLL_INTERVAL while alive?(pid) && Time.now < deadline
      signal_group(pid, "KILL") if alive?(pid)
      FileUtils.rm_f(paths.daemon_file)
    end

    # The port kept from last time, unless something else has taken it. A
    # PORT in the .env pins it instead. Returns [port, previous port if it
    # had to change].
    def choose_port
      settings, = EnvFile.load(paths.env_file)
      if (pinned = settings["PORT"].to_s.strip) != ""
        port = Integer(pinned, 10)
        raise Error, "PORT #{port} from #{paths.env_file} is already in use" unless port_free?(port)

        return [ port, nil ]
      end

      kept = read_if_exists(paths.port_file).to_s.strip
      kept = kept.empty? ? nil : Integer(kept, 10)
      return [ kept, nil ] if kept && port_free?(kept)

      [ free_port, kept ]
    rescue ArgumentError
      raise Error, "PORT in #{paths.env_file} is not a number"
    end

    def wait_until_up!(pid, port)
      deadline = Time.now + @startup_timeout
      until up?(port)
        raise Error, "Paneyard exited while starting. Last lines of #{paths.log_file}:\n#{log_tail}" unless alive?(pid)
        if Time.now > deadline
          raise Error, "Paneyard (pid #{pid}) did not answer on port #{port} within #{@startup_timeout}s. " \
            "Last lines of #{paths.log_file}:\n#{log_tail}"
        end

        sleep POLL_INTERVAL
      end
    end

    def up?(port)
      Net::HTTP.start("127.0.0.1", port, open_timeout: 2, read_timeout: 5) { |http| http.get("/up") }.is_a?(Net::HTTPSuccess)
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
      false
    end

    # A recorded pid is only ours if it is alive and started when ours did:
    # after a reboot the number may belong to anything.
    def live_state
      state = JSON.parse(read_if_exists(paths.daemon_file) || "null")
      return nil unless state.is_a?(Hash) && alive?(state["pid"])
      return nil if state["identity"] && identity(state["pid"]) != state["identity"]

      state
    rescue JSON::ParserError
      nil
    end

    def identity(pid)
      output = IO.popen([ "ps", "-o", "lstart=", "-p", pid.to_s ], err: File::NULL, &:read).strip
      output.empty? ? nil : output
    rescue SystemCallError
      nil
    end

    def alive?(pid)
      return false unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_group(pid, name)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill(name, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    def port_free?(port)
      TCPServer.new("127.0.0.1", port).close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def rotate_log
      return unless File.exist?(paths.log_file) && File.size(paths.log_file) > LOG_ROTATE_BYTES

      File.rename(paths.log_file, "#{paths.log_file}.1")
    end

    def log_tail(lines = 40)
      File.exist?(paths.log_file) ? File.readlines(paths.log_file).last(lines).join : ""
    end

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, content)
      File.rename(temp, path)
    end

    def read_if_exists(path)
      File.exist?(path) ? File.read(path) : nil
    end
  end
end
