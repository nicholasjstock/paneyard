require "jwt"
require "open3"
require "json"
require "openssl"

module Orchestrator
  module GitHubAppAuth
    class Error < StandardError; end

    class << self
      # Check if GitHub App is configured with required credentials.
      #
      # @return [Boolean] true if app ID and private key are available
      def app_configured?
        app_id_present? && private_key_present?
      end

      # Get or generate a GitHub App installation token for the repository.
      # This token can be used with `gh` CLI via GH_TOKEN env var or other authenticated calls.
      #
      # The block returns the repository's origin URL. The checkout lives on
      # the runner's machine, not here, so it is only asked for when the
      # installation has to be looked up by owner (no cached token and no
      # GITHUB_APP_INSTALLATION_ID).
      #
      # @yieldreturn [String] the repository's `origin` remote URL
      # @return [String] GitHub App installation token
      # @raise [Error] if app credentials are not configured or token generation fails
      def installation_token_for(&remote_url)
        cached_token = get_cached_token
        return cached_token if cached_token.present?

        token = generate_installation_token(remote_url)
        cache_token(token)
        token
      end

      private

      # Generate a GitHub App installation token using the app's private key.
      #
      # Steps:
      # 1. Create a JWT signed with the app's private key
      # 2. Use JWT to get a list of installations
      # 3. Get the installation ID for this workspace
      # 4. Exchange JWT for an installation access token
      def generate_installation_token(remote_url)
        app_id = load_app_id
        private_key = load_private_key
        installation_id = find_installation_id(remote_url)

        jwt_token = create_jwt(app_id, private_key)
        get_installation_access_token(jwt_token, installation_id)
      end

      def app_id_present?
        ENV["GITHUB_APP_ID"].present? || Rails.application.credentials.dig(:github_app, :id).present?
      end

      def private_key_present?
        ENV["GITHUB_APP_PRIVATE_KEY"].present? || Rails.application.credentials.dig(:github_app, :private_key).present?
      end

      def load_app_id
        app_id = ENV["GITHUB_APP_ID"] || Rails.application.credentials.dig(:github_app, :id)
        raise Error, "GitHub App ID not configured. Set GITHUB_APP_ID env var or config/credentials.yml" unless app_id.present?
        app_id.to_s
      end

      def load_private_key
        # Try environment variable first, then credentials
        private_key = ENV["GITHUB_APP_PRIVATE_KEY"] || Rails.application.credentials.dig(:github_app, :private_key)
        raise Error, "GitHub App private key not configured. Set GITHUB_APP_PRIVATE_KEY env var or config/credentials.yml" unless private_key.present?
        private_key
      end

      def create_jwt(app_id, private_key)
        payload = {
          iss: app_id,
          iat: Time.now.to_i,
          exp: (Time.now + 10.minutes).to_i
        }
        # RS256 requires an actual RSA key object, not the raw PEM text --
        # passing the PEM string directly raises JWT::EncodeError.
        JWT.encode(payload, OpenSSL::PKey::RSA.new(private_key), "RS256")
      rescue OpenSSL::PKey::RSAError => e
        raise Error, "GitHub App private key is not a valid PEM-formatted RSA key: #{e.message}"
      end

      def find_installation_id(remote_url)
        # A pre-configured installation ID means we never need the repository's
        # own remote URL at all -- looking it up unconditionally here broke
        # every caller that already knows the installation (including a repo
        # path that isn't a real git checkout, e.g. in tests).
        installation_id = ENV["GITHUB_APP_INSTALLATION_ID"]
        return installation_id if installation_id.present?

        repository = get_repository_info(remote_url&.call)
        app_id = load_app_id
        private_key = load_private_key

        jwt_token = create_jwt(app_id, private_key)
        find_installation_for_repository(jwt_token, repository)
      end

      def get_repository_info(url)
        raise Error, "Failed to get repository info: no origin remote URL" if url.blank?

        url = url.strip
        # Handle both HTTPS and SSH URLs
        # HTTPS: https://github.com/owner/repo.git or https://github.com/owner/repo
        # SSH: git@github.com:owner/repo.git
        match = url.match(%r{(?:https://github\.com/|git@github\.com:)([^/]+)/(.+?)(?:\.git)?$})
        raise Error, "Invalid GitHub repository URL: #{url}" unless match

        { owner: match[1], repo: match[2].gsub(".git", "") }
      end

      def find_installation_for_repository(jwt_token, repository)
        installation_id = ENV["GITHUB_APP_INSTALLATION_ID"]
        return installation_id if installation_id.present?

        # Try to find installation via API
        output, error, status = Open3.capture3(
          "curl", "-s", "-H", "Accept: application/vnd.github.v3+json",
          "-H", "Authorization: Bearer #{jwt_token}",
          "https://api.github.com/app/installations"
        )
        unless status.success?
          raise Error, "Failed to get app installations: #{error}"
        end

        installations = JSON.parse(output)
        target = installations.find do |inst|
          acct = inst.dig("account", "login")
          acct && acct.casecmp(repository[:owner]) == 0
        end

        unless target
          raise Error, "GitHub App not installed for repository #{repository[:owner]}/#{repository[:repo]}"
        end

        target["id"].to_s
      end

      def get_installation_access_token(jwt_token, installation_id)
        output, error, status = Open3.capture3(
          "curl", "-s", "-X", "POST",
          "-H", "Accept: application/vnd.github.v3+json",
          "-H", "Authorization: Bearer #{jwt_token}",
          "https://api.github.com/app/installations/#{installation_id}/access_tokens"
        )
        unless status.success?
          raise Error, "Failed to get installation access token: #{error}"
        end

        response = JSON.parse(output)
        raise Error, "GitHub API error: #{response["message"]}" if response["message"].present?
        raise Error, "No token in response" unless response["token"].present?

        response["token"]
      end

      def get_cached_token
        # Cache key for installation tokens (scoped to app instance)
        cache_key = "github_app_token:#{ENV['GITHUB_APP_ID'] || 'default'}"
        Rails.cache.read(cache_key)
      end

      def cache_token(token)
        cache_key = "github_app_token:#{ENV['GITHUB_APP_ID'] || 'default'}"
        # Cache for 55 minutes (GitHub tokens are valid for 1 hour)
        Rails.cache.write(cache_key, token, expires_in: 55.minutes)
      end
    end
  end
end
