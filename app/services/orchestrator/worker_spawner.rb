require "open3"
require "shellwords"
require "tmpdir"

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
      write_scope: nil, allowed_paths: [], model_tier: "small", mcp_override: nil, inherited_artifacts: [],
      lineage_key: nil, effort: nil)
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

      policy = WorkerExecutionPolicy.new(
        root_dir:, mode:, write_scope: write_scope.presence || "source_protected", allowed_paths:,
        protected_patterns: run.workspace.protected_write_patterns,
        extra_writable_absolute_paths: git_managed_extra_writable_paths(run:, write_scope:),
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
          target_root: root_dir, driver:
        ) + enriched_prompt
        enriched_prompt = workspace_memory_prompt(run) + enriched_prompt
      end
      # write_worker_mcp_config's output (a .mcp.json-shaped file) is only
      # ever read by claude, via --mcp-config below -- codex_args wires the
      # same MCP server(s) entirely through inline -c overrides instead
      # (see this file's own header comment on why the two CLIs can't share
      # one config format/mechanism at all). Skipping the write for codex
      # avoids persisting a file neither the process nor anything else
      # (confirmed: referenced nowhere outside this file) ever reads back.
      if mcp_override
        write_worker_mcp_config(
          mcp_config_path, mcp_override[:token], server_name: "chaperone", url: mcp_override[:url]
        ) if driver == "claude"
      else
        capability_token, capability_token_digest = Worker.issue_capability
        if driver == "claude"
          write_worker_mcp_config(mcp_config_path, capability_token)
          write_claude_settings(claude_settings_path, policy)
        end
      end
      # A resumed session picks up wherever its predecessor's conversation
      # left off (same codebase understanding, same discovered context) --
      # scoped to (run, role, launcher) so it can never cross a role or CLI
      # boundary (see prior_worker_for_resume) and never applies to a chaperone/mcp_override
      # spawn, which always gets a fully fresh, non-persisted session.
      resume_from = prior_worker_for_resume(run_id: run.run_id, role:, driver:) unless mcp_override
      resume_session_id = resume_from&.cli_session_id
      # One path for both drivers: neither pre-assigns a session id anymore.
      # Claude mints its own on a fresh spawn, same as codex always has --
      # WorkerReconcileJob captures it from the log afterward (see
      # Orchestrator::LogReader.claude_session_id/codex_session_id) unless
      # this spawn is itself resuming a known prior one.
      cli_session_id = mcp_override ? nil : resume_session_id

      # Keyed on (run_id, role), not cli_session_id/worker_id: Claude Code's
      # own session storage is scoped to the working directory a session
      # was created in, so a --resume from a different directory can never
      # find it -- this is what produced "No conversation found with
      # session ID" on every resumed spawn before e4440f9 keyed this on
      # worker_id's successor, cli_session_id. That fix broke again the
      # moment cli_session_id stopped being pre-assigned (above): a fresh
      # claude spawn now has no session id yet, so cli_session_id || worker_id
      # would fall through to worker_id -- a fresh, different value on
      # every single spawn, reproducing the exact original bug. (run_id,
      # role) is the one thing guaranteed identical between the spawn that
      # creates a session and any later spawn that resumes it --
      # prior_worker_for_resume already scopes its own lookup the same way,
      # and Orchestrator::SpawnRequestedWorkers.call_locked guarantees at
      # most one worker is ever active per run, so this directory is never
      # contended between two live processes either.
      runtime_dir = Rails.root.join("tmp", "workers", "#{ArtifactStore.sanitize_run_id(run.run_id)}-#{role}").to_s
      FileUtils.mkdir_p(runtime_dir)
      # XDG_CACHE_HOME is a cross-tool cache-location standard. Use a unique
      # directory beneath the OS temporary root: every worker sandbox grants
      # that root write access, unlike a user home directory or a target
      # repository. This is deliberately not a repo-specific RuboCop setting.
      cache_dir = File.join(Dir.tmpdir, "workflow-worker-cache", worker_id)
      FileUtils.mkdir_p(cache_dir)

      # An explicit effort: argument (e.g. the chaperone spawn) always wins;
      # otherwise fall back to the role's own persona-declared default.
      effective_effort = effort || persona_declared_effort(role)

      command, args =
        if driver == "claude"
          [ "claude", claude_args(
            enriched_prompt, role:, mode:, mcp_config_path:, settings_path: claude_settings_path,
            target_root: root_dir, policy:, model_tier:, mcp_override:,
            resume_session_id:, effort: effective_effort
          ) ]
        else
          validate_codex_permission_profile_compatibility!(root_dir)
          [ "codex", codex_args(
            root_dir:, last_message_path:, policy:, model_tier:, mcp_override:, resume_session_id:, effort: effective_effort
          ) ]
        end

      worker_env = build_worker_env.merge(
        "WORKER_LOG_PATH" => log_path,
        "WORKFLOW_RUN_ID" => run.run_id,
        "WORKFLOW_WORKER_ID" => worker_id,
        "WORKFLOW_WORKER_NICKNAME" => nickname,
        "WORKFLOW_WORKER_SCOPE" => scope,
        "WORKFLOW_WORKER_TOKEN" => capability_token,
        "WORKFLOW_CHAPERONE_TOKEN" => mcp_override&.dig(:token),
        # Tools such as RuboCop initialize caches before reading command-line
        # options. Keep disposable caches out of the sandboxed user's
        # ~/.cache and the target repository.
        "XDG_CACHE_HOME" => cache_dir
      ).merge(git_worker_env(role, run))

      File.write(prompt_path, enriched_prompt)
      File.write(log_path, "")
      File.delete(last_message_path) if File.exist?(last_message_path)
      File.delete(exit_status_path) if File.exist?(exit_status_path)
      File.write(env_path, "#{JSON.pretty_generate(build_worker_env_snapshot(worker_env))}\n")

      worker = run.workers.create!(
        worker_id:, role:, nickname:, reason:, scope:, status: "launching", pid: 0,
        prompt_path:, log_path:, last_message_path:, exit_status_path:, env_path:, mcp_config_path:,
        command:, args: [], model: selected_model, capability_token_digest:, execution_mode: mode,
        write_scope:, allowed_paths: Array(allowed_paths), inherited_artifacts: Array(inherited_artifacts),
        lineage_key:, cli_session_id:
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

    # One CLI session per (run, role): every same-role spawn resumes the
    # most recent completed same-role session in the run, so a later worker
    # inherits its predecessor's codebase understanding instead of
    # re-exploring from scratch (~80-90k cache-creation tokens per cold start,
    # observed). A worker that never completed its handoff has no valid
    # conversation to resume and must fall through to a fresh session.
    # Dispatch is single-flight per run (see SpawnRequestedWorkers), so
    # same-role sessions are never resumed concurrently. The role predicate
    # is the reliability boundary and lives here, not in caller convention:
    # a role transition (worker -> verifier -> git, or into
    # chaperone) always gets a fresh session -- a verifier must never
    # inherit the implementer's own reasoning trail. Accepted trade-off:
    # within one role, a confused worker's context now carries into the
    # next attempt.
    #
    # Excludes a worker whose CLI session never actually got established
    # server-side (claude's own "No conversation found with session ID"
    # immediate crash, num_turns=0) -- without this, the next same-role
    # spawn would --resume that exact dead session, crash identically, and
    # every spawn after that would keep inheriting the same broken id
    # forever. A worker still actively running is kept as a valid candidate
    # even though its agent_turn_count isn't captured yet (only populated
    # on reconciliation) -- but a worker that has already stopped and still
    # has no agent_turn_count is NOT given that same pass: it was stopped
    # (crashed, or killed by StopRunJob, which sets status directly and
    # never runs WorkerReconcileJob's usage-parsing) without ever proving
    # its session established, which is exactly as untrustworthy as a
    # known-zero session -- confirmed against a real run where the
    # *original* session-minting worker had been manually killed after
    # already erroring, sat at agent_turn_count=nil forever, and kept
    # getting selected as a "valid" resume source under the older, looser
    # NULL-tolerant version of this filter. Falls back further in history,
    # or to a brand-new session (see cli_session_id ||= SecureRandom.uuid
    # below) if nothing usable remains -- the chaperone backstop mentioned
    # above only diagnoses a session that has genuinely gone bad; it was
    # never what breaks the dead session out of rotation.
    def prior_worker_for_resume(run_id:, role:, driver: "claude")
      reconcile_pending_session_ids!(run_id:, role:, driver:)
      Worker.where(run_id:, role:, command: driver)
        .where.not(cli_session_id: nil)
        # A session id can be captured before the first worker_turn. Such a
        # predecessor may have exited before its CLI conversation existed.
        # An actively running predecessor remains eligible before its handoff
        # is reconciled; stopped predecessors must have completed their handoff
        # so a crashed or manually stopped session cannot rotate forever.
        .where("status = ? OR handoff_completed_at IS NOT NULL", "running")
        .order(created_at: :desc)
        .first
    end

    # Neither driver receives an incoming session id anymore -- both mint
    # their own on a fresh spawn, so it's only knowable after the fact, from
    # the worker's own log. WorkerReconcileJob's recurring tick used to be
    # the only thing that ever backfilled this, which meant a same-role
    # worker spawned before that tick ran would find no eligible resume
    # candidate at all, even though its predecessor's session was perfectly
    # resumable -- a real, accepted-at-the-time race. Reconciling
    # synchronously right here, exactly when this decision actually needs
    # it, closes that gap; WorkerReconcileJob no longer does this at all.
    def reconcile_pending_session_ids!(run_id:, role:, driver:)
      Worker.where(run_id:, role:, command: driver, status: "stopped", cli_session_id: nil).find_each do |worker|
        session_id = begin
          driver == "codex" ? Orchestrator::LogReader.codex_session_id(worker.log_path) : Orchestrator::LogReader.claude_session_id(worker.log_path)
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
        worker.update_column(:cli_session_id, session_id) if session_id.present?
      end
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

    # A linked git worktree's own .git is just a one-line pointer file --
    # the real metadata it writes to (HEAD, index) plus the shared objects/
    # refs every worktree writes into (confirmed empirically: git add/commit
    # touches .git/objects/** and .git/refs/heads/<branch>; push/fetch also
    # touch .git/refs/remotes/**) all live back in the source checkout's
    # .git/, entirely outside this worker's root_dir. Granting the whole
    # .git/ directory (never the source checkout's actual working-tree
    # files, which live in source_root itself, outside .git/) is simpler and
    # more robust than enumerating every internal git path that might need
    # writing, and matches git's own worktree safety model: concurrent
    # worktrees already share one .git/ database safely by design.
    def git_managed_extra_writable_paths(run:, write_scope:)
      return [] unless write_scope == "git_managed"
      return [] if run.source_root.blank?

      [ File.join(run.source_root, ".git") ]
    end

    # Print mode normally writes only a final response. Stream JSON with
    # partial messages gives the file-backed worker log incremental progress
    # for the run dashboard's five-second Turbo refreshes.
    # Agent instructions are plain prompt text, so Claude does not read any
    # front matter in agent_personas/*.md as model configuration. Keep
    # cost routing here at the actual CLI boundary instead.
    def claude_args(prompt, role: "worker", mode: nil, mcp_config_path:, settings_path:, target_root:, policy:,
      model_tier: "small", mcp_override: nil, resume_session_id: nil, effort: nil)
      if mcp_override
        # Without an explicit --output-format, --print defaults to plain
        # text -- not the structured JSON stream Orchestrator::LogReader.
        # claude_usage/claude_final_response (and therefore
        # WorkerReconcileJob's cost/usage persistence) already know how to
        # parse for every other claude worker. Matching that format here is
        # the only change needed: chaperone cost was never actually free,
        # it just was never captured.
        return [
          "--model", claude_model_for(role, mode:, model_tier:),
          *(effort ? [ "--effort", effort ] : []),
          "--print",
          "--mcp-config", mcp_config_path,
          "--strict-mcp-config",
          "--allowedTools", mcp_override[:allowed_tools].map { |name| "mcp__chaperone__#{name}" }.join(","),
          "--no-session-persistence",
          "--output-format", "stream-json",
          "--include-partial-messages",
          "--verbose",
          "--", prompt
        ]
      end

      [
        "--model", claude_model_for(role, mode:, model_tier:),
        *(effort ? [ "--effort", effort ] : []),
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
        *(resume_session_id ? [ "--resume", resume_session_id ] : []),
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

    def codex_args(root_dir:, last_message_path:, policy:, model_tier: "small", mcp_override: nil, resume_session_id: nil, effort: nil)
      model_args = [ "--model", codex_model_for(model_tier:) ]
      # No dedicated --reasoning-effort/--effort flag exists for codex --
      # confirmed against `codex exec --help` -- it's set the same way any
      # other config value is, via -c model_reasoning_effort="...".
      effort_args = effort ? [ "-c", %(model_reasoning_effort="#{effort}") ] : []
      if mcp_override
        return [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
          *model_args, *effort_args,
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

      # --json is what makes the session_meta line (containing codex's own
      # generated session id) actually appear in the captured worker log --
      # see Orchestrator::LogReader.codex_session_id. `codex exec resume`
      # does not accept -C/--add-dir (confirmed against `codex exec resume
      # --help`); the resumed session keeps whatever cwd it started with.
      if resume_session_id
        [ "exec", "resume", resume_session_id, *model_args, *effort_args, "--json", *config_args, "-o", last_message_path, "-" ]
      else
        [ "exec", *model_args, *effort_args, "--json", *config_args, "-C", root_dir, "-o", last_message_path, "-" ]
      end
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
      target_root:, driver:)
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
        The workflow bus tools are MCP tools registered under the `mcp__workflow__` prefix (e.g.
        `mcp__workflow__worker_turn`, `mcp__workflow__write_workflow_artifact`). If they are not directly
        callable, they are deferred: load them FIRST with ToolSearch using their full prefixed names (e.g.
        query `select:mcp__workflow__worker_turn`) -- bare, unprefixed names will not match. Never state or
        imply that you called a tool you did not actually invoke; if a required tool cannot be loaded or
        called, say exactly that in your final message instead of narrating a call that never happened.
        The target workspace root is `#{target_root}`. Start repository commands with `cd #{Shellwords.escape(target_root)}`.
        #{"This process did not start inside #{target_root} (it only has read/tool access to it, granted separately) -- so CLAUDE.md is not auto-loaded the way it would be from a normal session there. Read #{target_root}/CLAUDE.md before making any repository changes.\n" if driver == "claude"}Bash is available under a launcher-enforced filesystem policy. Writes to tracked repository source are limited
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

    # One persona file per role, shared by both drivers (agent_personas/) --
    # confirmed the .claude/.codex copies of these were duplicated, not
    # genuinely different: near-identical or verbatim content, manually
    # kept in sync by hand, which already caused real drift once (a stale
    # pre-Rails-orchestrator instruction block existed only in the .md
    # copy). The old per-driver metadata these used to carry (model,
    # model_reasoning_effort, sandbox_mode) was confirmed never read by
    # anything -- this one exception (a leading `---\neffort: ...\n---`
    # block) is deliberately real: persona_declared_effort below actually
    # parses it and threads it into the real --effort/-c
    # model_reasoning_effort flags, so a role's default effort lives in one
    # place its own persona file, not hardcoded per call site.
    PERSONA_FRONTMATTER = /\A---\n(.*?)\n---\n+/m

    def build_prompt_with_persona(driver:, role:, prompt:)
      persona_paths = [ agent_prompt_path(role) ]
      if role == "infrastructure"
        # Infrastructure keeps the normal worker bus contract and layers on
        # the repository-owned reliability workflow.
        persona_paths.unshift(agent_prompt_path("worker"))
        persona_paths << infrastructure_skill_path
      elsif role == "verifier"
        # A verifier keeps the normal worker bus contract (worker_turn,
        # get_run_context, etc.) and layers on its own independent-review
        # discipline.
        persona_paths.unshift(agent_prompt_path("worker"))
      end
      instructions = persona_paths.filter_map { |path| persona_body(path) }
      return prompt if instructions.empty?

      "#{instructions.join("\n\n")}\n\nCurrent task:\n#{prompt}"
    end

    # Only ever read from the role's own file, never a folded-in base (e.g.
    # verifier/infrastructure also fold in worker.md) -- a base persona's
    # own effort declaration, if it ever has one, describes that base role,
    # not every role layered on top of it.
    def persona_declared_effort(role)
      path = agent_prompt_path(role)
      return nil unless File.exist?(path)

      frontmatter = File.read(path)[PERSONA_FRONTMATTER, 1]
      frontmatter&.[](/^effort:\s*(\S+)/, 1)
    end

    def persona_body(path)
      return nil unless File.exist?(path)

      File.read(path).sub(PERSONA_FRONTMATTER, "")
    end

    def agent_prompt_path(role)
      File.join(Rails.root, "agent_personas", "#{role}.md")
    end

    def infrastructure_skill_path
      Rails.root.join("agent_personas", "infrastructure_skill.md")
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

    # `gh` and plain `git push`/`fetch` normally authenticate via the OS
    # keychain (gh's own credential store, or git's osxkeychain helper on
    # macOS) -- both need Keychain Services access a sandboxed child process
    # cannot get non-interactively. Confirmed live: even after granting the
    # git role real .git write access, its actual gh/git commands still
    # failed once genuinely spawned in the sandbox ("gh CLI token invalid").
    # Scoped to the git role alone -- every other role stays exactly as
    # git-blind as WorkerExecutionPolicy already makes them; nothing else
    # should ever receive a git/gh credential at all.
    #
    # Prefers a GitHub App installation token (GitHubAppAuth) when one is
    # configured -- scoped to this one repository/installation, not the
    # operator's own identity -- falling back to the operator's ambient
    # `gh auth token` (exactly like read_codex_auth_api_key already does for
    # OPENAI_API_KEY) when the App isn't configured or a token request fails,
    # so publication keeps working either way. Either way, GH_TOKEN lets gh
    # skip the keychain entirely -- it always prefers GH_TOKEN/GITHUB_TOKEN
    # over a stored credential. The GIT_CONFIG_* pair appends gh's own
    # credential helper (which likewise honors GH_TOKEN) so plain git
    # push/fetch authenticate the same way; it appends rather than replaces
    # the host's existing helper(s), so GIT_TERMINAL_PROMPT=0 guarantees that
    # if an earlier, keychain-backed helper can't run in this sandbox, git
    # treats that as a fast failure and falls through instead of blocking on
    # an interactive prompt nothing can answer.
    def git_worker_env(role, run)
      return {} unless role == "git"

      token = git_worker_token(run)
      return {} if token.blank?

      {
        "GH_TOKEN" => token,
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "credential.helper",
        "GIT_CONFIG_VALUE_0" => "!gh auth git-credential"
      }
    end

    def git_worker_token(run)
      if GitHubAppAuth.app_configured?
        begin
          return GitHubAppAuth.installation_token_for(workspace_root: run.target_root)
        rescue GitHubAppAuth::Error => e
          Rails.logger.warn("WorkerSpawner: GitHub App token unavailable, falling back to ambient gh auth: #{e.message}")
        end
      end

      gh_auth_token
    end

    def gh_auth_token
      output, _error, status = Open3.capture3("gh", "auth", "token")
      status.success? ? output.strip.presence : nil
    rescue Errno::ENOENT
      nil
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
        XDG_CACHE_HOME: resolved.call("XDG_CACHE_HOME"),
        WORKER_LOG_PATH: resolved.call("WORKER_LOG_PATH"),
        WORKFLOW_RUN_ID: resolved.call("WORKFLOW_RUN_ID"),
        WORKFLOW_WORKER_ID: resolved.call("WORKFLOW_WORKER_ID"),
        WORKFLOW_WORKER_NICKNAME: resolved.call("WORKFLOW_WORKER_NICKNAME"),
        WORKFLOW_WORKER_SCOPE: resolved.call("WORKFLOW_WORKER_SCOPE"),
        WORKFLOW_WORKER_TOKEN: resolved.call("WORKFLOW_WORKER_TOKEN").present? ? "[set]" : nil,
        WORKFLOW_CHAPERONE_TOKEN: resolved.call("WORKFLOW_CHAPERONE_TOKEN").present? ? "[set]" : nil,
        GH_TOKEN: resolved.call("GH_TOKEN").present? ? "[set]" : nil,
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
