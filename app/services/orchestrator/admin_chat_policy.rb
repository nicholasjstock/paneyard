require "pathname"

module Orchestrator
  # Confines a workspace admin-chat turn to reading.
  #
  # The admin chat is the remote-control surface: it runs from the workspace
  # root, where it can see the durable `main` checkout *and* every in-flight
  # run's worktree, and it is reachable from Telegram. It must therefore never
  # be able to write to a repository -- least of all into a worktree whose own
  # session is actively working in it. Anything that should change code goes
  # through a queued run instead (`queue_run`), which gets a worktree, a
  # branch, and a pull request you review.
  #
  # This is the read-only half of the old per-step WorkerExecutionPolicy,
  # kept because its shape was established against real sandbox failures
  # rather than from documentation -- see the notes on each method. Every
  # write scope, allowed-path, and protected-pattern knob is gone: this
  # policy has exactly one mode.
  #
  # Bash stays available on purpose. Inspection is most of what this chat
  # does and it needs real commands (`git log`, `gh pr view`, reading a test
  # run's output). The constraint is the OS-level sandbox, not the tool list,
  # so the chat can look at anything and change nothing.
  module AdminChatPolicy
    module_function

    PROFILE_NAME = "admin_chat".freeze
    CLAUDE_TOOLS = %w[Bash Read Grep Glob ToolSearch].freeze

    def claude_tools
      CLAUDE_TOOLS.join(",")
    end

    # `permission-mode bypassPermissions` still applies (nobody is present to
    # answer an interactive prompt, and "dontAsk" silently denies instead of
    # asking) -- so the real boundary is this settings file. `allow` keeps the
    # turn from stalling; `sandbox.filesystem.allowWrite` is what actually
    # stops it writing, and `allowUnsandboxedCommands: false` stops Bash
    # escaping it.
    def claude_settings(workspace_root, mcp_server_name: "admin")
      root = absolute(workspace_root)
      {
        "permissions" => {
          "allow" => [ "Bash", "Read(#{root}/**)", "Grep", "Glob", "mcp__#{mcp_server_name}__*" ]
        },
        "sandbox" => {
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => { "allowWrite" => [ Dir.tmpdir ] }
        }
      }
    end

    # `:root => read` and an enabled network deliberately widen this beyond
    # the workspace, and both were established by reproducing real failures
    # with `codex sandbox --log-denials` rather than from documentation:
    #
    #   - any host toolchain manager (asdf, nvm, rbenv, ...) installs outside
    #     the workspace root, under $HOME or a package-manager prefix, so no
    #     finite set of extra readable roots covers every repo and host;
    #   - the chat needs the network for `gh` to answer questions about pull
    #     requests at all.
    #
    # Neither widens *writing*: `:tmpdir` is the only write grant, so the
    # read-only guarantee is unaffected.
    #
    # Passed as `-c` overrides rather than `--sandbox read-only` because
    # `codex exec resume` does not accept `--sandbox` (a resumed session keeps
    # whatever it started with) but does accept `-c`. Setting it both ways
    # means a resumed turn is confined exactly like a fresh one, instead of
    # inheriting a sandbox nobody re-stated.
    def codex_config_overrides
      filesystem = {
        ":minimal" => "read",
        ":tmpdir" => "write",
        ":root" => "read",
        ":workspace_roots" => { "." => "read" }
      }

      [
        toml_assignment("default_permissions", PROFILE_NAME),
        toml_assignment("permissions.#{PROFILE_NAME}.filesystem", filesystem),
        toml_assignment("permissions.#{PROFILE_NAME}.network", { "enabled" => true })
      ].flat_map { |override| [ "-c", override ] }
    end

    def write_claude_settings(path, workspace_root, mcp_server_name: "admin")
      File.write(path, "#{JSON.pretty_generate(claude_settings(workspace_root, mcp_server_name:))}\n")
      File.chmod(0o600, path)
      path
    end

    def absolute(path)
      "/#{Pathname(path).expand_path.to_s.delete_prefix('/')}"
    end

    def toml_assignment(key, value)
      "#{key}=#{toml_value(value)}"
    end

    def toml_value(value)
      case value
      when String then value.to_json
      when TrueClass, FalseClass then value.to_s
      when Hash then "{#{value.map { |key, item| "#{key.to_json}=#{toml_value(item)}" }.join(',')}}"
      else raise ArgumentError, "Unsupported TOML policy value: #{value.inspect}"
      end
    end
  end
end
