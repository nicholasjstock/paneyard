require "shellwords"

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
    CODEX_SMALL_MODEL = "gpt-5.6-luna"
    CODEX_PROMOTED_MODEL = "gpt-5.6-terra"
    CODEX_WORKER_MODEL = CODEX_SMALL_MODEL

    def spawn_worker(run:, role:, nickname:, reason:, scope:, prompt:, worker_id: nil, mode: nil,
      write_scope: nil, allowed_paths: [], model_tier: "small", mcp_override: nil)
      raise ArgumentError, "Planner processes were removed; queue a PlannerDecisionJob instead" if role == "planner"

      # nickname flows straight into file paths under workers_dir below --
      # unlike runId (see Orchestrator::ArtifactStore.sanitize_run_id) the
      # original TS spawnWorkerInputShape never constrained nickname's
      # characters either, so this same gap existed pre-port. Closing it
      # here rather than carrying it forward: nickname is caller-supplied
      # on every spawn path (spawn_worker MCP tool, and the ops UI has no
      # server-side control over what a planner/worker asks for).
      validate_safe_path_segment!(nickname)
      TargetPreflight.check!(run:, mode:)

      root_dir = run.target_root
      workers_dir = File.join(ArtifactStore.output_dir(root_dir), "workers")
      FileUtils.mkdir_p(workers_dir)

      worker_id ||= SecureRandom.uuid
      file_basename = worker_file_basename(run_id: run.run_id, nickname: nickname)
      prompt_path = File.join(workers_dir, "#{file_basename}.prompt.txt")
      log_path = File.join(workers_dir, "#{file_basename}.log")
      last_message_path = File.join(workers_dir, "#{file_basename}.last-message.txt")
      exit_status_path = File.join(workers_dir, "#{file_basename}.exit-status.txt")
      env_path = File.join(workers_dir, "#{file_basename}.env.json")
      mcp_config_path = File.join(workers_dir, "#{file_basename}.mcp.json")
      claude_settings_path = File.join(workers_dir, "#{file_basename}.claude-settings.json")
      runtime_dir = Rails.root.join("tmp", "workers", worker_id).to_s
      FileUtils.mkdir_p(runtime_dir)

      policy = WorkerExecutionPolicy.new(
        root_dir:, mode:, write_scope: write_scope.presence || "source_protected", allowed_paths:,
        protected_patterns: run.workspace.protected_write_patterns,
        profile_name: "worker-#{worker_id.delete('-')}"
      ) unless mcp_override

      driver = run.launcher_variant
      selected_model = if driver == "claude"
        claude_model_for(role, mode:, model_tier:)
      else
        codex_model_for(model_tier:) || "default"
      end
      enriched_prompt = build_prompt_with_persona(driver: driver, role: role, prompt: prompt)
      unless mcp_override
        enriched_prompt = worker_identity_prompt(
          run_id: run.run_id, worker_id:, nickname:, role:, scope:, mode:, write_scope:, allowed_paths:,
          target_root: root_dir
        ) + enriched_prompt
        enriched_prompt = workspace_memory_prompt(run) + enriched_prompt
      end
      if mcp_override
        write_worker_mcp_config(
          mcp_config_path, mcp_override[:token], server_name: "chaperone", url: mcp_override[:url]
        )
      else
        capability_token, capability_token_digest = Worker.issue_capability
        write_worker_mcp_config(mcp_config_path, capability_token)
        write_claude_settings(claude_settings_path, policy) if driver == "claude"
      end
      command, args =
        if driver == "claude"
          [ "claude", claude_args(
            enriched_prompt, role:, mode:, mcp_config_path:, settings_path: claude_settings_path,
            target_root: root_dir, policy:, model_tier:, mcp_override:
          ) ]
        else
          validate_codex_permission_profile_compatibility!(root_dir)
          [ "codex", codex_args(
            root_dir:, last_message_path:, policy:, model_tier:, mcp_override:
          ) ]
        end

      worker_env = build_worker_env.merge(
        "WORKER_LOG_PATH" => log_path,
        "WORKFLOW_RUN_ID" => run.run_id,
        "WORKFLOW_WORKER_ID" => worker_id,
        "WORKFLOW_WORKER_NICKNAME" => nickname,
        "WORKFLOW_WORKER_SCOPE" => scope,
        "WORKFLOW_WORKER_TOKEN" => capability_token,
        "WORKFLOW_CHAPERONE_TOKEN" => mcp_override&.dig(:token)
      )

      File.write(prompt_path, enriched_prompt)
      File.write(log_path, "")
      File.delete(last_message_path) if File.exist?(last_message_path)
      File.delete(exit_status_path) if File.exist?(exit_status_path)
      File.write(env_path, "#{JSON.pretty_generate(build_worker_env_snapshot(worker_env))}\n")

      worker = run.workers.create!(
        worker_id:, role:, nickname:, reason:, scope:, status: "launching", pid: 0,
        prompt_path:, log_path:, last_message_path:, exit_status_path:, env_path:, mcp_config_path:,
        command:, args: [], model: selected_model, capability_token_digest:, execution_mode: mode,
        write_scope:, allowed_paths: Array(allowed_paths)
      )

      # Brakeman flags this as command injection because command/args/paths
      # trace back to caller-supplied role/nickname/scope. Safe as written:
      # command is always the literal "claude" or "codex" (never derived
      # from input), args is an argv array (no shell involved, so no
      # metacharacter can escape its argument boundary), and nickname --
      # the only piece of this that reaches a file path -- is validated by
      # validate_safe_path_segment! above before any path is built from it.
      stdin_read, stdin_write = IO.pipe
      pid = Process.spawn(
        worker_env, "/bin/sh", "-c", worker_exit_wrapper, "workflow-worker-wrapper", exit_status_path, command, *args,
        chdir: driver == "claude" ? runtime_dir : root_dir,
        pgroup: true, in: stdin_read, out: [ log_path, "a" ], err: [ log_path, "a" ]
      )
      stdin_read.close
      stdin_write.write(enriched_prompt) if driver != "claude"
      stdin_write.close
      Process.detach(pid)

      worker.update!(status: "running", pid:, args:)

      append_lifecycle_line(
        log_path, event: "spawned", worker_id: worker.worker_id, run_id: run.run_id, role: role,
        nickname: nickname, pid: pid, scope: scope, reason: reason, command: command, status: "running"
      )

      worker
    rescue => error
      worker&.update!(status: "stopped", stopped_at: Time.current, stop_reason: "Worker failed to launch: #{error.message}")
      raise
    end

    def stop_worker(worker:, reason:)
      if worker.status == "running"
        begin
          Process.kill("SIGTERM", -worker.pid) if process_alive?(worker.pid)
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

    def worker_file_basename(run_id:, nickname:)
      "#{ArtifactStore.sanitize_run_id(run_id)}-#{nickname}"
    end

    # Print mode normally writes only a final response. Stream JSON with
    # partial messages gives the file-backed worker log incremental progress
    # for the run dashboard's five-second Turbo refreshes.
    # Agent instructions are plain prompt text, so Claude does not read the
    # YAML front matter in .claude/agents/*.md as model configuration. Keep
    # cost routing here at the actual CLI boundary instead.
    def claude_args(prompt, role: "worker", mode: nil, mcp_config_path:, settings_path:, target_root:, policy:,
      model_tier: "small", mcp_override: nil)
      if mcp_override
        return [
          "--model", claude_model_for(role, mode:, model_tier:),
          "--print",
          "--mcp-config", mcp_config_path,
          "--strict-mcp-config",
          "--allowedTools", mcp_override[:allowed_tools].map { |name| "mcp__chaperone__#{name}" }.join(","),
          "--no-session-persistence",
          "--", prompt
        ]
      end

      [
        "--model", claude_model_for(role, mode:, model_tier:),
        # "dontAsk" silently denies (rather than approves) any action the
        # CLI's own automated safety classifier flags as needing
        # confirmation -- e.g. an edit that looks like it's deleting a test
        # assertion -- regardless of what settings_path's own allow-list
        # already grants. With no human present to actually confirm, a
        # worker hitting that gets a permission_denials entry it then has
        # to rationalize instead of correctly reporting [BLOCKED]. The real
        # write boundary is the sandbox settings below, not this flag --
        # bypassPermissions skips the redundant, human-shaped gate on top
        # of it.
        "--permission-mode", "bypassPermissions",
        "--tools", policy.claude_tools,
        "--settings", settings_path,
        "--setting-sources", "",
        "--add-dir", target_root,
        "--mcp-config", mcp_config_path,
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p", "--", prompt
      ]
    end

    def claude_model_for(role, mode: nil, model_tier: "small")
      model_tier.to_s == "strong" ? "sonnet" : "haiku"
    end

    def codex_model_for(model_tier: "small")
      model_tier.to_s == "strong" ? CODEX_PROMOTED_MODEL : CODEX_SMALL_MODEL
    end

    def codex_args(root_dir:, last_message_path:, policy:, model_tier: "small", mcp_override: nil)
      model_args = [ "--model", codex_model_for(model_tier:) ]
      if mcp_override
        return [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
          *model_args,
          "-c", %(mcp_servers.chaperone.url=#{mcp_override[:url].to_json}),
          "-c", %(mcp_servers.chaperone.bearer_token_env_var="WORKFLOW_CHAPERONE_TOKEN"),
          "-c", %(mcp_servers.chaperone.default_tools_approval_mode="approve"),
          "-C", root_dir, "-o", last_message_path, "-"
        ]
      end

      mcp_overrides = [
        %(mcp_servers.workflow.url=#{"#{rails_mcp_url}/worker".to_json}),
        %(mcp_servers.workflow.bearer_token_env_var="WORKFLOW_WORKER_TOKEN"),
        %(mcp_servers.workflow.default_tools_approval_mode="approve")
      ]
      config_args = (policy.codex_config_overrides + mcp_overrides).flat_map { |override| [ "-c", override ] }

      [
        "exec", *model_args,
        *config_args, "-C", root_dir, "-o", last_message_path, "-"
      ]
    end

    # Codex permission profiles and the legacy sandbox_mode setting are
    # mutually exclusive. If any active user or project config still declares
    # sandbox_mode, Codex would ignore our exact-path profile. Fail closed
    # rather than launch a worker with broader access than its persisted policy.
    def validate_codex_permission_profile_compatibility!(root_dir)
      config_paths = [ File.join(root_dir, ".codex", "config.toml") ]
      codex_home = resolve_codex_home
      config_paths << File.join(codex_home, "config.toml") if codex_home.present?
      incompatible = config_paths.select do |path|
        File.exist?(path) && File.foreach(path).any? { |line| line.match?(/^\s*sandbox_mode\s*=/) }
      end
      return if incompatible.empty?

      raise ArgumentError,
        "Codex worker policy cannot coexist with legacy sandbox_mode in #{incompatible.join(', ')}"
    end

    # The shell remains the tracked process while the CLI runs. It records the
    # CLI's exit code before exiting so reconciliation can distinguish a quota
    # rejection from an unobserved process disappearance.
    def worker_exit_wrapper
      'exit_status_path="$1"; shift; "$@"; exit_code=$?; printf "%s\\n" "$exit_code" > "$exit_status_path"; exit "$exit_code"'
    end

    def rails_mcp_url
      base = ENV.fetch("WORKFLOW_RAILS_URL", "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}")
      "#{base}/mcp"
    end

    def write_worker_mcp_config(path, token, server_name: "workflow", url: nil)
      config = {
        "mcpServers" => {
          server_name => {
            "type" => "http", "url" => url || "#{rails_mcp_url}/worker",
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

    def worker_identity_prompt(run_id:, worker_id:, nickname:, role:, scope:, mode:, write_scope:, allowed_paths:,
      target_root:)
      <<~PROMPT
        # Runtime identity (authoritative)

        - runId: #{run_id}
        - workerId: #{worker_id}
        - nickname: #{nickname}
        - role: #{role}
        - scope/artifact: #{scope}
        - execution mode: #{mode || "unspecified"}
        - write scope: #{write_scope || "unspecified"}
        - authorized workspace source roots: #{Array(allowed_paths).presence&.join(", ") || "none"}

        Rails authenticates MCP calls with this worker's private capability. Do not invent or alter identity fields.
        `worker_turn` derives nickname and scope from that capability; pass runId, role, task, and result.
        The target workspace root is `#{target_root}`. Start repository commands with `cd #{Shellwords.escape(target_root)}`.
        Bash is available under a launcher-enforced filesystem policy. Writes to tracked repository source are limited
        to the authorized source roots above -- source-protected workers have none. Gitignored paths (caches, build
        output, node_modules, etc.) stay writable regardless, since tooling needs them and they aren't source. Run
        bounded commands (they
        exit on their own) in the foreground through Bash so they remain inside this worker's sandbox and process
        group. Any command that is long-running by nature (a dev server, a watcher, anything that does not exit on
        its own) MUST always be started with `start_run_command` instead, even if you only need it for the rest of
        this turn -- `&`, `nohup`, and log redirection do not reliably keep a process alive even across your own
        next Bash call.
        Use `write_workflow_artifact` for the assigned artifact.

      PROMPT
    end

    # Prepended so no worker has to remember to ask for this -- see
    # Orchestrator::ProjectInitTrigger/RecordProjectSetupTool for how these
    # entries get written. Reuses ProjectMemory.snapshot's own brief bound
    # (top entries, truncated content) rather than querying the table directly.
    def workspace_memory_prompt(run)
      entries = ProjectMemory.snapshot(run_id: run.run_id)[:entries]
      return "" if entries.empty?

      lines = entries.map { |entry| "- [#{entry[:kind]}] #{entry[:key]}: #{entry[:content]}" }
      <<~PROMPT
        # Durable project knowledge for this workspace (evidence-backed; call get_project_memory for full detail if needed)

        #{lines.join("\n")}

      PROMPT
    end

    def build_prompt_with_persona(driver:, role:, prompt:)
      persona_paths = [ agent_prompt_path(driver: driver, role: role) ]
      if role == "infrastructure"
        # Infrastructure keeps the normal worker bus contract and layers on
        # the launcher-specific, repository-owned reliability workflow.
        persona_paths.unshift(agent_prompt_path(driver: driver, role: "worker"))
        persona_paths << infrastructure_skill_path(driver)
      elsif role == "verifier"
        # A verifier keeps the normal worker bus contract (worker_turn,
        # get_run_context, etc.) and layers on its own independent-review
        # discipline.
        persona_paths.unshift(agent_prompt_path(driver: driver, role: "worker"))
      end
      instructions = persona_paths.filter_map { |path| File.read(path) if File.exist?(path) }
      return prompt if instructions.empty?

      "#{instructions.join("\n\n")}\n\nCurrent task:\n#{prompt}"
    end

    def agent_prompt_path(driver:, role:)
      extension = driver == "claude" ? "md" : "toml"
      File.join(Rails.root, ".#{driver}", "agents", "#{role}.#{extension}")
    end

    def infrastructure_skill_path(driver)
      Rails.root.join(".#{driver}", "skills", "infrastructure", "SKILL.md")
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

    # config/boot.rb's `require "bundler/setup"` activates this orchestrator's
    # own Gemfile by setting these vars on the Rails process's OS environment.
    # Process.spawn merges a given env hash onto the parent's environment
    # rather than replacing it, so without unsetting them explicitly, a
    # worker's own `bundle exec` (e.g. running the target repo's test suite)
    # would resolve gems against this app's Gemfile.lock instead of the
    # target repo's. A nil value here removes the var from the child while
    # leaving the rest of this process's environment -- including anything a
    # test harness or deployment sets -- inherited normally (see
    # spec/support/fake_agent_harness.rb, which depends on exactly that).
    BUNDLER_ACTIVATION_ENV_KEYS = %w[
      BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLE_APP_CONFIG
      BUNDLER_VERSION BUNDLER_SETUP RUBYOPT GEM_HOME GEM_PATH
    ].freeze

    # This Rails process may itself have been started from inside a Claude
    # Code session (e.g. `bin/dev` run from a Claude Code terminal, or --
    # as in this repo's own development -- launched by an agent's own Bash
    # tool). Without stripping these, a spawned `claude` child inherits
    # CLAUDE_CODE_CHILD_SESSION=1 and disables its own transcript saving,
    # treating itself as a nested session of whatever spawned Rails.
    # CLAUDE_CONFIG_DIR is deliberately left alone -- it points at the
    # user's real config/credentials and spawned CLIs still need it.
    NESTED_CLAUDE_CODE_ENV_KEYS = %w[
      CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID
      CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_EFFORT AI_AGENT
    ].freeze

    def build_worker_env
      codex_home = resolve_codex_home
      worker_env = (BUNDLER_ACTIVATION_ENV_KEYS + NESTED_CLAUDE_CODE_ENV_KEYS).index_with { nil }
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
        WORKER_LOG_PATH: resolved.call("WORKER_LOG_PATH"),
        WORKFLOW_RUN_ID: resolved.call("WORKFLOW_RUN_ID"),
        WORKFLOW_WORKER_ID: resolved.call("WORKFLOW_WORKER_ID"),
        WORKFLOW_WORKER_NICKNAME: resolved.call("WORKFLOW_WORKER_NICKNAME"),
        WORKFLOW_WORKER_SCOPE: resolved.call("WORKFLOW_WORKER_SCOPE"),
        WORKFLOW_WORKER_TOKEN: resolved.call("WORKFLOW_WORKER_TOKEN").present? ? "[set]" : nil,
        WORKFLOW_CHAPERONE_TOKEN: resolved.call("WORKFLOW_CHAPERONE_TOKEN").present? ? "[set]" : nil,
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
