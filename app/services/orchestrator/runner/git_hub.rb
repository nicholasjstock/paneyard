require "open3"

module Orchestrator
  module Runner
    # The GitHub CLI (`gh`) on the runner's machine, as Projects uses it to
    # get a project ready: whether it is installed and logged in, who is
    # logged in, whether an owner exists and may be created under, whether a
    # repository exists, `gh repo create` and `gh repo clone`. Nothing else in Paneyard calls
    # GitHub; sessions push with git as the operator.
    #
    # Every call runs with prompts off, so a missing login or credential fails
    # instead of waiting on a terminal nobody is looking at.
    module GitHub
      module_function

      ENV_OFF_PROMPTS = { "GH_PROMPT_DISABLED" => "1", "GIT_TERMINAL_PROMPT" => "0", "NO_COLOR" => "1" }.freeze

      # The gh to run. Specs point it at a fake.
      def executable
        "gh"
      end

      def installed?
        run("--version").last
      rescue SystemCallError
        false
      end

      def authenticated?
        run("auth", "status").last
      end

      # The logged-in user's login, or nil.
      def login
        output, _error, ok = run("api", "user", "--jq", ".login")
        ok ? output.strip.presence : nil
      end

      # "User", "Organization", :missing, or [:error, message].
      def owner_type(owner)
        output, error, ok = run("api", "users/#{owner}", "--jq", ".type")
        return output.strip if ok
        return :missing if not_found?(error)

        [ :error, error.strip ]
      end

      # Whether `login` is an active member of the organization: true, false,
      # or nil when GitHub would not say (a token without read:org, say), in
      # which case creating the repository is what finds out.
      def org_member?(org)
        output, error, ok = run("api", "user/memberships/orgs/#{org}", "--jq", ".state")
        return output.strip == "active" if ok
        return false if not_found?(error)

        nil
      end

      # true, false, or [:error, message].
      def repository_exists?(full_name)
        _output, error, ok = run("api", "repos/#{full_name}", "--silent")
        return true if ok
        return false if not_found?(error)

        [ :error, error.strip ]
      end

      # Clones the repository into `target`, which must not exist. Returns
      # [ok, message].
      def clone_repository(full_name:, target:)
        Sandbox.guard_github!("clone a GitHub repository")
        output, error, ok = run("repo", "clone", full_name, target.to_s, "--", "--quiet")
        [ ok, (error.presence || output).to_s.strip ]
      rescue Sandbox::Violation, SystemCallError => error
        [ false, error.message ]
      end

      # Creates the repository and adds it as the local checkout's origin,
      # pushing nothing: the caller pushes the branch it means to be the
      # default. Returns [ok, message].
      def create_repository(full_name:, visibility:, source:, description: nil)
        Sandbox.guard_github!("create a GitHub repository")
        args = [ "repo", "create", full_name, "--#{visibility}", "--source", source.to_s, "--remote", "origin" ]
        args += [ "--description", description ] if description.present?
        output, error, ok = run(*args)
        [ ok, (error.presence || output).to_s.strip ]
      rescue Sandbox::Violation, SystemCallError => error
        [ false, error.message ]
      end

      # https://github.com/<full_name>, from the repository's own record.
      def repository_url(full_name)
        output, _error, ok = run("api", "repos/#{full_name}", "--jq", ".html_url")
        ok ? output.strip.presence : nil
      end

      def not_found?(error)
        error.to_s.include?("HTTP 404") || error.to_s.include?("Not Found")
      end

      # [stdout, stderr, success?]
      def run(*args)
        output, error, status = Open3.capture3(ENV_OFF_PROMPTS, executable, *args)
        [ output, error, status.success? ]
      end
    end
  end
end
