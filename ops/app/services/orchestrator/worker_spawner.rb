module Orchestrator
  # Ports scripts/workflow-worker-spawn.ts's spawnWorkerProcess -- forks a
  # real codex/claude CLI subprocess against a run's workspace. Unlike the
  # TS version, also writes each driver's own MCP config into the
  # workspace pointing at this Rails app's MCP endpoint (this config used
  # to be a permanently git-tracked file living in the target project
  # itself; generating it fresh here, like promptPath/logPath already
  # were, removes that per-target-project setup requirement entirely).
  #
  # claude and codex do NOT share a config format or file -- confirmed by
  # directly spawning a real worker against a real MCP server during this
  # port and finding codex simply had zero tools available despite a
  # correctly-configured .mcp.json:
  #   - claude reads .mcp.json at the project root: {"mcpServers":
  #     {"workflow": {"type": "http", "url": "..."}}}.
  #   - codex does not read .mcp.json at all. It reads .codex/config.toml
  #     (project-scoped, requires the project to already be `trusted` in
  #     ~/.codex/config.toml) with its own schema: [mcp_servers.workflow]
  #     url = "..." (a bare url key selects streamable HTTP; a `command`
  #     key would select stdio instead -- the two are mutually exclusive
  #     per table).
  module WorkerSpawner
    module_function

    MASKED_API_KEY_VALUES = [ "", "[set]", "[secure]", "[redacted]" ].freeze

    def spawn_worker(run:, role:, nickname:, reason:, scope:, prompt:, worker_id: nil)
      # nickname flows straight into file paths under workers_dir below --
      # unlike runId (see Orchestrator::ArtifactStore.sanitize_run_id) the
      # original TS spawnWorkerInputShape never constrained nickname's
      # characters either, so this same gap existed pre-port. Closing it
      # here rather than carrying it forward: nickname is caller-supplied
      # on every spawn path (spawn_worker MCP tool, and the ops UI has no
      # server-side control over what a planner/worker asks for).
      validate_safe_path_segment!(nickname)

      root_dir = run.target_root
      workers_dir = File.join(root_dir, "front", "demo-output", "agents-sdk", "workers")
      FileUtils.mkdir_p(workers_dir)

      worker_id ||= SecureRandom.uuid
      prompt_path = File.join(workers_dir, "#{nickname}.prompt.txt")
      log_path = File.join(workers_dir, "#{nickname}.log")
      last_message_path = File.join(workers_dir, "#{nickname}.last-message.txt")
      env_path = File.join(workers_dir, "#{nickname}.env.json")

      # claude resolves --agent <role> against .claude/agents/<role>.md
      # itself, so the persona must not also be prepended into the prompt
      # the way it is for codex (which has no equivalent named-agent flag).
      driver = run.launcher_variant
      enriched_prompt = driver == "claude" ? prompt : build_prompt_with_persona(root_dir, role, prompt)
      command, args =
        if driver == "claude"
          [ "claude", [ "--agent", role, "--permission-mode", "bypassPermissions", "-p", "--", enriched_prompt ] ]
        else
          [ "codex", [ "exec", "--dangerously-bypass-approvals-and-sandbox", "-C", root_dir, "-o", last_message_path, "-" ] ]
        end

      driver == "claude" ? write_claude_mcp_config(root_dir) : write_codex_mcp_config(root_dir)
      worker_env = build_worker_env

      File.write(prompt_path, enriched_prompt)
      File.write(log_path, "")
      File.write(env_path, "#{JSON.pretty_generate(build_worker_env_snapshot(worker_env))}\n")

      # Brakeman flags this as command injection because command/args/paths
      # trace back to caller-supplied role/nickname/scope. Safe as written:
      # command is always the literal "claude" or "codex" (never derived
      # from input), args is an argv array (no shell involved, so no
      # metacharacter can escape its argument boundary), and nickname --
      # the only piece of this that reaches a file path -- is validated by
      # validate_safe_path_segment! above before any path is built from it.
      stdin_read, stdin_write = IO.pipe
      pid = Process.spawn(
        worker_env, command, *args,
        chdir: root_dir, pgroup: true, in: stdin_read, out: [ log_path, "a" ], err: [ log_path, "a" ]
      )
      stdin_read.close
      stdin_write.write(enriched_prompt) if driver != "claude"
      stdin_write.close
      Process.detach(pid)

      worker = run.workers.create!(
        worker_id: worker_id, role: role, nickname: nickname, reason: reason, scope: scope,
        status: "running", pid: pid, prompt_path: prompt_path, log_path: log_path,
        last_message_path: last_message_path, env_path: env_path, command: command, args: args
      )

      append_lifecycle_line(
        log_path, event: "spawned", worker_id: worker.worker_id, run_id: run.run_id, role: role,
        nickname: nickname, pid: pid, scope: scope, reason: reason, command: command, status: "running"
      )

      worker
    end

    def stop_worker(worker:, reason:)
      if worker.status == "running"
        begin
          Process.kill("SIGTERM", worker.pid) if process_alive?(worker.pid)
        rescue Errno::ESRCH
          nil
        end
      end

      worker.update!(status: "stopped", stopped_at: Time.current, stop_reason: reason)
      append_lifecycle_line(
        worker.log_path, event: "stopped", worker_id: worker.worker_id, run_id: worker.run_id, role: worker.role,
        nickname: worker.nickname, pid: worker.pid, scope: worker.scope, reason: worker.reason,
        command: worker.command, status: "stopped", stop_reason: reason
      )
      worker
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def validate_safe_path_segment!(value)
      if value.blank? || value == "." || value == ".." || value.include?("/") || value.include?("\\") || value.include?("\0")
        raise ArgumentError, "Unsafe worker nickname: #{value.inspect}"
      end
    end

    def rails_mcp_url
      base = ENV.fetch("WORKFLOW_RAILS_URL", "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}")
      "#{base}/mcp"
    end

    def write_claude_mcp_config(root_dir)
      config = { "mcpServers" => { "workflow" => { "type" => "http", "url" => rails_mcp_url } } }
      File.write(File.join(root_dir, ".mcp.json"), "#{JSON.pretty_generate(config)}\n")
    end

    # .codex/config.toml is a hand-maintained file that can hold other
    # unrelated settings ([features], [agents], etc) -- rather than a full
    # TOML round-trip (no TOML-writing gem is in this app's dependency
    # set, and adding one for this one narrow, fixed-shape block isn't
    # worth it), this replaces just the [mcp_servers.workflow] table
    # in-place by text, leaving everything else in the file untouched.
    def write_codex_mcp_config(root_dir)
      config_path = File.join(root_dir, ".codex", "config.toml")
      new_block = <<~TOML
        [mcp_servers.workflow]
        url = "#{rails_mcp_url}"
        default_tools_approval_mode = "approve"
      TOML

      existing = File.exist?(config_path) ? File.read(config_path) : ""
      table_pattern = /^\[mcp_servers\.workflow\].*?(?=^\[|\z)/m
      updated = existing.match?(table_pattern) ? existing.sub(table_pattern, new_block) : "#{existing.chomp}\n\n#{new_block}".lstrip

      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, updated)
    end

    def build_prompt_with_persona(root_dir, role, prompt)
      persona_path = File.join(root_dir, ".codex", "agents", "#{role}.toml")
      return prompt unless File.exist?(persona_path)

      "#{File.read(persona_path)}\n\nCurrent task:\n#{prompt}"
    end

    def resolve_codex_home
      home_dir = ENV["HOME"]
      default_codex_home =
        if ENV["XDG_CONFIG_HOME"].present?
          File.join(ENV["XDG_CONFIG_HOME"], "codex")
        elsif home_dir.present?
          File.join(home_dir, ".config", "codex")
        end
      configured_codex_home = ENV["CODEX_HOME"]
      has_auth_json = ->(dir) { dir.present? && File.exist?(File.join(dir, "auth.json")) }

      return configured_codex_home if has_auth_json.call(configured_codex_home)
      return default_codex_home if has_auth_json.call(default_codex_home)

      configured_codex_home || default_codex_home
    end

    def read_codex_auth_api_key(codex_home)
      return nil if codex_home.blank?

      auth_path = File.join(codex_home, "auth.json")
      return nil unless File.exist?(auth_path)

      parsed = JSON.parse(File.read(auth_path))
      api_key = parsed["OPENAI_API_KEY"]
      return api_key if api_key.is_a?(String) && api_key.strip.present?

      access_token = parsed.dig("tokens", "access_token")
      return access_token if access_token.is_a?(String) && access_token.strip.present?

      nil
    rescue
      nil
    end

    def build_worker_env
      codex_home = resolve_codex_home
      worker_env = { "HOME" => ENV["HOME"], "PATH" => ENV["PATH"] }
      worker_env["CODEX_HOME"] = codex_home if codex_home.present?

      api_key = ENV["OPENAI_API_KEY"]
      if api_key.blank?
        api_key = read_codex_auth_api_key(codex_home)
        worker_env["OPENAI_API_KEY"] = api_key if api_key.present?
      end

      masked = api_key&.strip&.downcase
      # A placeholder value could leak in from an inherited/redacted env --
      # unset it explicitly (nil in a Process.spawn env hash removes the
      # var from the child, since Ruby merges this hash with the parent's
      # env by default rather than replacing it).
      worker_env["OPENAI_API_KEY"] = nil if masked.blank? || MASKED_API_KEY_VALUES.include?(masked)

      worker_env
    end

    def build_worker_env_snapshot(worker_env)
      resolved = ->(key) { worker_env.key?(key) ? worker_env[key] : ENV[key] }
      {
        HOME: resolved.call("HOME"),
        CODEX_HOME: resolved.call("CODEX_HOME"),
        PATH: resolved.call("PATH"),
        SHELL: resolved.call("SHELL"),
        USER: resolved.call("USER"),
        LOGNAME: resolved.call("LOGNAME"),
        TMPDIR: resolved.call("TMPDIR"),
        OPENAI_API_KEY: resolved.call("OPENAI_API_KEY").present? ? "[set]" : nil,
        OPENAI_BASE_URL: resolved.call("OPENAI_BASE_URL")
      }
    end

    def append_lifecycle_line(log_path, event:, worker_id:, run_id:, role:, nickname:, pid:, scope:, reason:, command:, status:, stop_reason: nil)
      details = {
        worker_id: worker_id, run_id: run_id, role: role, nickname: nickname, pid: pid, scope: scope,
        reason: reason, command: command, status: status, stop_reason: stop_reason
      }
      line = "[workflow] #{Time.now.utc.iso8601(3)} worker:lifecycle: #{event} #{nickname} #{details.to_json}\n"
      File.write(log_path, line, mode: "a")
    end
  end
end
