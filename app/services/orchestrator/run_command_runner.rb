require "pathname"
require "open3"

module Orchestrator
  # Rails-owned lifecycle for a run-scoped background command: spawns a
  # detached process group outside any worker's own process group (contrast
  # with Orchestrator::WorkerSpawner, whose children die with the worker),
  # reconciles persisted status against OS state, and stops it on request.
  #
  # Reuses WorkerSpawner.worker_exit_wrapper's shell trick so the tracked pid
  # is a thin `/bin/sh -c` wrapper that captures the real exit status to a
  # file -- this is what lets reconciliation recover an exit code even after
  # a Rails restart severs the Process.detach reaper thread for an
  # in-flight command.
  #
  # PID-reuse limitation: ownership is checked via Process.getpgid(pid) ==
  # process_group_id (the group leader's pgid always equals its own pid), not
  # just liveness. An unrelated process reusing this exact pid AND happening
  # to be its own process group leader with the same pgid is not impossible,
  # only very unlikely. There is no portable, dependency-free way to pin an
  # exact process-start timestamp in stock Ruby, so this is accepted for v1
  # given the "trusted local execution" scope of this feature.
  #
  # No per-worker write-scope enforcement: unlike WorkerExecutionPolicy (which
  # restricts a scoped-fix worker's Bash tool to its exact allowed_paths at
  # the native Claude/Codex sandbox layer), this module only checks that
  # working_directory sits under the run's target_root -- a long-running
  # command (a dev server, a watcher) can write anywhere under the workspace
  # regardless of the starting worker's write_scope. Accepted as a known,
  # deliberate gap for v1; redesign if/when that containment matters here.
  module RunCommandRunner
    module_function

    DEFAULT_LOG_READ_LIMIT = 8_000
    MAX_LOG_READ_LIMIT = 65_536
    STOP_GRACE_PERIOD = 2.0
    STOP_POLL_INTERVAL = 0.1
    PENDING_STUCK_AFTER = 30.seconds

    def start(run:, requested_by_worker_id:, executable:, arguments: [], working_directory: nil, environment: {}, purpose: nil)
      raise ArgumentError, "executable is required" if executable.blank?

      root_dir = run.target_root
      target_dir = resolve_working_directory(root_dir, working_directory)
      commands_dir = File.join(ArtifactStore.output_dir(root_dir), "commands")
      FileUtils.mkdir_p(commands_dir)

      command = run.run_commands.create!(
        requested_by_worker_id:, executable:, arguments: Array(arguments), working_directory: target_dir,
        environment: environment.to_h, purpose:, status: "pending"
      )

      basename = "#{ArtifactStore.sanitize_run_id(run.run_id)}-#{command.command_id}"
      log_path = File.join(commands_dir, "#{basename}.log")
      exit_status_path = File.join(commands_dir, "#{basename}.exit-status.txt")
      File.write(log_path, "")

      spawn_env = { "HOME" => ENV["HOME"], "PATH" => ENV["PATH"] }.merge(environment.to_h.transform_keys(&:to_s))

      # unsetenv_others: true is required here -- Process.spawn otherwise
      # merges spawn_env onto this Rails process's own OS environment
      # rather than replacing it, so this orchestrator's own Bundler
      # activation (BUNDLE_GEMFILE, RUBYOPT, GEM_HOME -- set by
      # config/boot.rb's `require "bundler/setup"`) would leak into a
      # target-repo command, making a Ruby/Bundler-based command (e.g. a
      # `bin/dev` that shells out to `bundle exec foreman`) resolve gems
      # against this app's Gemfile.lock instead of the target repo's.
      pid = Process.spawn(
        spawn_env, "/bin/sh", "-c", WorkerSpawner.worker_exit_wrapper, "run-command-wrapper",
        exit_status_path, executable, *Array(arguments).map(&:to_s),
        chdir: target_dir, pgroup: true, unsetenv_others: true,
        in: File::NULL, out: [ log_path, "a" ], err: [ log_path, "a" ]
      )
      Process.detach(pid)

      command.update!(
        status: "running", pid:, process_group_id: pid, log_path:, exit_status_path:,
        started_at: Time.current, last_checked_at: Time.current
      )
      command
    rescue => error
      command&.update!(status: "failed", failure_message: error.message, finished_at: Time.current)
      raise error if command.nil?

      command
    end

    def reconcile!(command)
      return command if command.terminal?
      return command if command.pid.blank?

      if process_alive?(command.pid) && owns_process?(command)
        detected_port = command.port || detect_listening_port(command)
        command.update!(last_checked_at: Time.current, port: detected_port)
        return command
      end

      # The tracked pid (the process-group leader) is gone, but a child it
      # spawned before exiting/crashing -- a dev server started by a
      # process manager like foreman, for instance -- can still be alive
      # in the same process group and keep holding a port. Best-effort,
      # one-time reap on this exited->terminal transition; harmless if
      # nothing (or nothing reachable) remains.
      reap_process_group!(command)

      exit_code, signal = read_exit_status(command.exit_status_path)
      if exit_code.nil? && signal.nil?
        command.update!(
          status: "lost", finished_at: Time.current, last_checked_at: Time.current,
          failure_message: command.failure_message.presence || "process no longer running; exit status unavailable"
        )
      else
        command.update!(status: "exited", exit_code:, signal:, finished_at: Time.current, last_checked_at: Time.current)
      end
      command
    end

    def reap_process_group!(command)
      return if command.process_group_id.blank?

      Process.kill("SIGTERM", -command.process_group_id)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def reconcile_active!
      RunCommand.where(status: "pending").where("created_at < ?", PENDING_STUCK_AFTER.ago).find_each do |command|
        command.update!(status: "lost", finished_at: Time.current, failure_message: "spawn did not complete")
      end
      RunCommand.where(status: "running").find_each { |command| reconcile!(command) }
    end

    def stop(command:, reason:)
      reconcile!(command)
      return command if command.terminal?

      unless owns_process?(command)
        command.update!(status: "lost", finished_at: Time.current, failure_message: "process ownership could not be verified before stop")
        return command
      end

      begin
        Process.kill("SIGTERM", -command.pid)
      rescue Errno::ESRCH
        nil
      end

      deadline = Time.current + STOP_GRACE_PERIOD
      sleep(STOP_POLL_INTERVAL) while Time.current < deadline && owns_process?(command)

      if owns_process?(command)
        begin
          Process.kill("SIGKILL", -command.pid)
        rescue Errno::ESRCH
          nil
        end
        sleep(STOP_POLL_INTERVAL)
      end

      exit_code, signal = read_exit_status(command.exit_status_path)
      command.update!(status: "stopped", exit_code:, signal:, finished_at: Time.current, failure_message: reason)
      command
    end

    def stop_all_for_run(run:, reason:)
      run.run_commands.active.find_each { |command| stop(command: command, reason: reason) }
    end

    def read_log_window(command, offset: 0, limit: DEFAULT_LOG_READ_LIMIT)
      path = command.log_path
      unless path.present? && File.exist?(path)
        return { text: "", cursor: offset.to_i, next_cursor: nil, has_more: false, truncated_start: false }
      end

      total_bytes = File.size(path)
      start_offset = offset.to_i.clamp(0, total_bytes)
      byte_limit = limit.to_i.clamp(1, MAX_LOG_READ_LIMIT)
      text = File.binread(path, byte_limit, start_offset).to_s.dup.force_encoding("UTF-8").scrub
      next_offset = start_offset + text.bytesize

      {
        text:, cursor: start_offset, next_cursor: next_offset < total_bytes ? next_offset : nil,
        has_more: next_offset < total_bytes, truncated_start: false
      }
    end

    def resolve_working_directory(root_dir, working_directory)
      clean_root = Pathname.new(root_dir).realpath
      return clean_root.to_s if working_directory.blank?

      candidate = Pathname.new(working_directory)
      target = candidate.absolute? ? candidate.cleanpath : clean_root.join(candidate).cleanpath
      raise ArgumentError, "workingDirectory does not exist" unless target.directory?

      resolved = target.realpath
      unless resolved.to_s == clean_root.to_s || resolved.to_s.start_with?("#{clean_root}/")
        raise ArgumentError, "workingDirectory escapes the run workspace"
      end

      resolved.to_s
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def owns_process?(command)
      return false unless process_alive?(command.pid)

      Process.getpgid(command.pid) == command.process_group_id
    rescue Errno::ESRCH
      false
    end

    # Best-effort: asks the OS what TCP port (if any) this command's process
    # group is actually listening on, rather than trusting a caller-reported
    # value -- the command may run under a process manager (foreman, an
    # npm script) that picks its own child pid and port. Silently returns
    # nil if lsof is unavailable or nothing is listening yet; reconcile!
    # retries this on every subsequent poll until a port appears.
    def detect_listening_port(command)
      return nil if command.process_group_id.blank?

      output, _error, status = Open3.capture3(
        "lsof", "-a", "-g", command.process_group_id.to_s, "-i", "-sTCP:LISTEN", "-n", "-P"
      )
      return nil unless status.success?

      output.each_line.drop(1).each do |line|
        match = line.match(/:(\d+)\s+\(LISTEN\)/)
        return Integer(match[1], 10) if match
      end
      nil
    rescue Errno::ENOENT
      nil
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
