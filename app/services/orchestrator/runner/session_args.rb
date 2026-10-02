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

      # Returns [command, args] for the given driver. Nothing goes in the
      # environment: a session's pane is the operator's own login shell
      # (herdr's worktree.create takes no env), so its /mcp/run capability
      # reaches the CLI in a config file (claude) or a -c override (codex).
      def build(driver:, root_dir:, mcp_config_path:, capability_token:, mcp_url:, model:, resume_session_id: nil)
        case driver
        when "claude" then [ "claude", claude_args(root_dir:, mcp_config_path:, resume_session_id:, model:) ]
        when "codex" then [ "codex", codex_args(root_dir:, mcp_url:, capability_token:, resume_session_id:, model:) ]
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
      #
      # The capability goes in as an http_headers override. Confirmed live on
      # 0.159.3, with nothing in the environment: codex sent
      # `Authorization: Bearer <token>` on initialize, the GET stream and
      # tools/list. (It used to be bearer_token_env_var, read from the pane's
      # env, which sessions no longer have.) The override is typed into the
      # pane's shell, so the token can land in the operator's shell history;
      # it is dead the moment the session ends (RunSession.authenticate_capability).
      def codex_args(root_dir:, mcp_url:, capability_token:, model:, resume_session_id: nil)
        config_args = [
          %(mcp_servers.paneyard.url=#{"#{mcp_url}/run".to_json}),
          %(mcp_servers.paneyard.http_headers={Authorization=#{"Bearer #{capability_token}".to_json}}),
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
