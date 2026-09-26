require "open3"

module Orchestrator
  # The environment a run's interactive CLI session gets, layered so a
  # workspace-recorded workaround can never shadow a value the orchestrator
  # itself manages.
  #
  # A nil value means "this variable must not be set in the session". herdr's
  # tab env map has no way to express that (Herdr.compact_env drops nils), but
  # a brand-new pane's shell never inherited this Rails process's environment
  # in the first place, so the nils below are belt-and-braces rather than
  # load-bearing -- they matter if a future caller ever spawns a session some
  # other way.
  module SessionEnv
    module_function

    MASKED_API_KEY_VALUES = [ "", "[set]", "[secure]", "[redacted]" ].freeze

    # config/boot.rb's `require "bundler/setup"` activates this orchestrator's
    # own Gemfile on the Rails process. A session running the target repo's
    # test suite must resolve gems against that repo's Gemfile.lock, not this
    # app's.
    BUNDLER_ACTIVATION_ENV_KEYS = %w[
      BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLE_APP_CONFIG
      BUNDLER_VERSION BUNDLER_SETUP RUBYOPT GEM_HOME GEM_PATH
    ].freeze

    # This Rails process may itself have been started from inside a Claude
    # Code session (this repo is one of its own registered Workspaces, so an
    # agent's Bash tool really does launch it). Left alone, a spawned `claude`
    # inherits CLAUDE_CODE_CHILD_SESSION=1 and disables its own transcript
    # saving, treating itself as a nested session. CLAUDE_CONFIG_DIR is
    # deliberately left alone -- it points at the operator's real credentials
    # and spawned CLIs still need it.
    NESTED_CLAUDE_CODE_ENV_KEYS = %w[
      CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID
      CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_EFFORT AI_AGENT
    ].freeze

    # bin/production sets RAILS_ENV on the orchestrator process itself. It is
    # scoped to this app's runtime and has no meaning for a target repo -- a
    # session running that repo's specs must be free to pick its own.
    RAILS_PROCESS_ENV_KEYS = %w[RAILS_ENV].freeze

    def for_session(run:, capability_token:, extra: {})
      base = WorkspaceEnvVars.for_workspace(run.workspace)
      base
        .merge(sanitized_process_env)
        .merge(
          "WORKFLOW_RUN_ID" => run.run_id,
          SessionArgs::TOKEN_ENV_VAR => capability_token
        )
        .merge(git_env(run))
        .merge(extra)
    end

    def sanitized_process_env
      codex_home = resolve_codex_home
      env = (BUNDLER_ACTIVATION_ENV_KEYS + NESTED_CLAUDE_CODE_ENV_KEYS + RAILS_PROCESS_ENV_KEYS).index_with { nil }
      env["CODEX_HOME"] = codex_home if codex_home.present?

      api_key = ENV["OPENAI_API_KEY"]
      if api_key.blank?
        api_key = read_codex_auth_api_key(codex_home)
        env["OPENAI_API_KEY"] = api_key if api_key.present?
      end

      masked = api_key&.strip&.downcase
      env["OPENAI_API_KEY"] = nil if masked.blank? || MASKED_API_KEY_VALUES.include?(masked)
      env
    end

    # Every session now commits and pushes its own branch -- there is no
    # separate git-role worker to hand credentials to any more -- so this is
    # unconditional rather than role-scoped.
    #
    # `gh` and plain `git push` normally authenticate via the OS keychain,
    # which a non-interactive child cannot reach. GH_TOKEN lets gh skip the
    # keychain entirely (it always prefers GH_TOKEN over a stored credential),
    # and the GIT_CONFIG_* triple appends gh's own credential helper so plain
    # git push/fetch authenticate the same way. It appends rather than
    # replaces the host's existing helpers, so GIT_TERMINAL_PROMPT=0
    # guarantees an unreachable keychain helper fails fast instead of blocking
    # on a prompt nothing can answer.
    #
    # Prefers a GitHub App installation token -- scoped to this one
    # repository/installation rather than the operator's whole identity --
    # falling back to ambient `gh auth token` when the App is not configured.
    def git_env(run)
      token = git_token(run)
      return {} if token.blank?

      {
        "GH_TOKEN" => token,
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "credential.helper",
        "GIT_CONFIG_VALUE_0" => "!gh auth git-credential"
      }
    end

    def git_token(run)
      if GitHubAppAuth.app_configured?
        begin
          return GitHubAppAuth.installation_token_for(workspace_root: run.target_root)
        rescue GitHubAppAuth::Error => e
          Rails.logger.warn("SessionEnv: GitHub App token unavailable, falling back to ambient gh auth: #{e.message}")
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
  end
end
