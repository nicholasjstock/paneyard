module Orchestrator
  module Runner
    # Builds the command line for one run's interactive CLI session, per driver.
    #
    # Every detail here was established by running these CLIs for real inside a
    # herdr pane, not by reading --help, and several of them contradict what the
    # help output implies. Do not "simplify" a flag out of this file without
    # re-verifying it live -- the notes on each method record what actually
    # broke.
    #
    # The prompt is deliberately NOT part of any command line: it is submitted
    # separately via Herdr.agent_prompt once the session reports ready, so a
    # multi-KB prompt never has to survive being typed as a shell argv element.
    #
    # Which model to run is the orchestrator's decision (the operator's pick,
    # else Orchestrator::DefaultModels), so `model` always arrives resolved --
    # nil meaning no model flag, so the CLI uses its own configured model.
    # So does `mcp_url`: the orchestrator's /mcp endpoint as this machine
    # reaches it.
    module SessionArgs
      module_function

      # The env var a session's CLI reads its /mcp/run capability from.
      TOKEN_ENV_VAR = "PANEYARD_RUN_TOKEN".freeze

      # Claude Code resolves a worktree's auto-memory to its main checkout, so
      # without this every claude run loads the operator's own per-repo memory
      # -- notes written for their everyday session, some of which contradict a
      # run's job (e.g. "queue a run instead of implementing it"). Confirmed in
      # the 2.1.283 binary: a truthy CLAUDE_CODE_DISABLE_AUTO_MEMORY turns auto
      # memory off.
      CLAUDE_ENV = { "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1" }.freeze

      # Returns [command, args, extra_env] for the given driver. extra_env is
      # merged into the pane's environment (opencode carries its whole MCP
      # config that way; the others point at a file or use -c overrides).
      def build(driver:, root_dir:, mcp_config_path:, capability_token:, mcp_url:, model:, resume_session_id: nil)
        case driver
        when "claude" then [ "claude", claude_args(root_dir:, mcp_config_path:, resume_session_id:, model:), CLAUDE_ENV.dup ]
        when "codex" then [ "codex", codex_args(root_dir:, mcp_url:, resume_session_id:, model:), {} ]
        when "opencode" then [ "opencode", *opencode_args(root_dir:, capability_token:, mcp_url:, resume_session_id:, model:) ]
        else raise ArgumentError, "unsupported driver: #{driver.inspect}"
        end
      end

      # Interactive claude. Confirmed live that --mcp-config/--add-dir/
      # --permission-mode work identically in a real interactive session -- they
      # are general CLI flags, not --print-specific.
      #
      # Deliberately absent compared to the old headless worker invocation:
      # --print/--output-format/--verbose (there is no stream-json log to
      # produce), --tools and --settings (those carried the planner's
      # per-step allowed-paths sandbox, which no longer exists -- a session owns
      # its whole worktree), --setting-sources "" (a session should load the
      # target repo's own CLAUDE.md and settings exactly as it would if the
      # operator ran `claude` by hand in that worktree), and
      # --disable-slash-commands (the operator types into this pane and should
      # keep their slash commands).
      #
      # --strict-mcp-config is kept: it guarantees the paneyard MCP server is
      # the one the session gets, and keeps startup predictable regardless of
      # whatever .mcp.json the target repo happens to ship.
      def claude_args(root_dir:, mcp_config_path:, model:, resume_session_id: nil)
        [
          *model_args("--model", model),
          "--permission-mode", "bypassPermissions",
          "--add-dir", root_dir,
          "--mcp-config", mcp_config_path,
          "--strict-mcp-config",
          *(resume_session_id ? [ "--resume", resume_session_id ] : [])
        ]
      end

      # Bare `codex` (no subcommand) is the real interactive TUI; `codex exec`
      # is its headless automation mode. Deliberately does NOT use
      # --dangerously-bypass-approvals-and-sandbox: confirmed live that this
      # exact flag, alone, with a completely fresh CODEX_HOME, makes
      # bare/interactive codex 0.147.0 fail immediately with "the argument
      # '--dangerously-bypass-approvals-and-sandbox' cannot be used multiple
      # times" (also seen as "...cannot be used with '--ask-for-approval'" when
      # combined with -a). It works fine for `codex exec`. `-s
      # danger-full-access` alone (no `-a`) is what actually works and was
      # confirmed live to reach a normal "permissions: YOLO mode" session with
      # no approval prompts.
      #
      # `codex resume <id>` mirrors `codex exec resume <id>`, which rejects -C
      # (a resumed session keeps the cwd it started with). Confirmed live on
      # 0.159.2 that `resume <id>` with the args below, and no -C, reopens the
      # conversation in its original cwd.
      #
      # check_for_update_on_startup=false is required. With an update pending,
      # the TUI opens on an "Update available" picker whose default choice is
      # "Update now (runs `brew upgrade --cask codex`)", so the prompt Paneyard
      # types plus its Enter picks it: codex upgraded itself, printed "Please
      # restart Codex." and exited before ever seeing the task. Confirmed live
      # on 0.159.2, fresh and resume, with a CODEX_HOME whose version.json
      # claimed 99.0.0: without the override the picker appears, with it the
      # session starts normally and takes a prompt. codex does flag an unknown
      # -c key ("`...` is ignored"), and does not flag this one. It is a
      # top-level ConfigToml key, and codex-rs/tui/src/updates.rs
      # (get_upgrade_version) returns early when it is false.
      def codex_args(root_dir:, mcp_url:, model:, resume_session_id: nil)
        config_args = [
          %(mcp_servers.paneyard.url=#{"#{mcp_url}/run".to_json}),
          %(mcp_servers.paneyard.bearer_token_env_var="#{TOKEN_ENV_VAR}"),
          %(mcp_servers.paneyard.default_tools_approval_mode="approve"),
          "check_for_update_on_startup=false"
        ].flat_map { |override| [ "-c", override ] }
        sandbox_args = [ "-s", "danger-full-access" ]

        if resume_session_id
          [ "resume", resume_session_id, *model_args("--model", model), *sandbox_args, *config_args ]
        else
          [ *model_args("--model", model), *sandbox_args, *config_args, "-C", root_dir ]
        end
      end

      # Returns [args, env]. Three corrections here were found only by running
      # it for real (confirmed against `opencode --help` vs `opencode run
      # --help`: --variant and --dir are `run`-subcommand-only flags that do not
      # exist on the bare command):
      #   - the working directory is a bare positional, not --dir;
      #   - --auto ("auto-approve permissions that are not explicitly denied")
      #     IS a top-level flag and is required, or the session sits blocked on
      #     tool-approval prompts;
      #   - --mini is required: the full default TUI never actually delivered
      #     agent.prompt's text into its input at all (confirmed live -- neither
      #     agent.prompt nor a raw pane.send_text reached it, even after an
      #     explicit Enter keypress); --mini's simpler renderer receives it
      #     correctly (the submitted prompt appeared verbatim and the agent
      #     began working).
      def opencode_args(root_dir:, capability_token:, mcp_url:, model:, resume_session_id: nil)
        config = JSON.generate({
          mcp: {
            paneyard: {
              type: "remote",
              url: "#{mcp_url}/run",
              headers: { Authorization: "Bearer #{capability_token}" }
            }
          }
        })

        args = [ *model_args("-m", model), "--auto", "--mini" ]
        args += [ "-s", resume_session_id ] if resume_session_id
        args << root_dir
        [ args, { "OPENCODE_CONFIG_CONTENT" => config } ]
      end

      # No model means the CLI's own configured default: leave the flag out.
      def model_args(flag, model)
        model.present? ? [ flag, model ] : []
      end

      def write_claude_mcp_config(path, capability_token, mcp_url:)
        config = {
          "mcpServers" => {
            "paneyard" => {
              "type" => "http",
              "url" => "#{mcp_url}/run",
              "headers" => { "Authorization" => "Bearer #{capability_token}" }
            }
          }
        }
        File.write(path, "#{JSON.pretty_generate(config)}\n")
        File.chmod(0o600, path)
        path
      end
    end
  end
end
