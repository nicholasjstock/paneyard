require "rails_helper"

RSpec.describe Orchestrator::GitHubAppAuth do
  # RS256 needs a real RSA key it can actually parse -- a placeholder string
  # between PEM headers raises OpenSSL::PKey::PKeyError, not the app-level
  # Error these specs mean to exercise. Generated once per suite run.
  TEST_RSA_PRIVATE_KEY = OpenSSL::PKey::RSA.generate(2048).to_pem.freeze

  describe ".app_configured?" do
    context "when GitHub App ID and private key are configured" do
      before do
        ENV["GITHUB_APP_ID"] = "12345"
        ENV["GITHUB_APP_PRIVATE_KEY"] = "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----"
      end

      after do
        ENV.delete("GITHUB_APP_ID")
        ENV.delete("GITHUB_APP_PRIVATE_KEY")
      end

      it "returns true" do
        expect(described_class.app_configured?).to be true
      end
    end

    context "when GitHub App ID is missing" do
      before do
        ENV["GITHUB_APP_ID"] = nil
        ENV["GITHUB_APP_PRIVATE_KEY"] = "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----"
      end

      after do
        ENV.delete("GITHUB_APP_PRIVATE_KEY")
      end

      it "returns false" do
        expect(described_class.app_configured?).to be false
      end
    end

    context "when private key is missing" do
      before do
        ENV["GITHUB_APP_ID"] = "12345"
        ENV["GITHUB_APP_PRIVATE_KEY"] = nil
      end

      after do
        ENV.delete("GITHUB_APP_ID")
      end

      it "returns false" do
        expect(described_class.app_configured?).to be false
      end
    end

    context "when both are missing" do
      before do
        ENV["GITHUB_APP_ID"] = nil
        ENV["GITHUB_APP_PRIVATE_KEY"] = nil
      end

      it "returns false" do
        expect(described_class.app_configured?).to be false
      end
    end
  end

  describe ".installation_token_for" do
    let(:remote_url) { "https://github.com/owner/repo.git" }
    let(:app_id) { "12345" }
    let(:private_key) { TEST_RSA_PRIVATE_KEY }
    let(:installation_id) { "67890" }
    let(:mock_token) { "ghu_test_token_abc123" }

    before do
      ENV["GITHUB_APP_ID"] = app_id
      ENV["GITHUB_APP_PRIVATE_KEY"] = private_key
      ENV["GITHUB_APP_INSTALLATION_ID"] = installation_id
      # The test environment's cache_store is :null_store (config/environments/test.rb),
      # which never actually stores anything -- swap in a real backing store for
      # this describe block since caching is exactly what it exercises.
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    after do
      ENV.delete("GITHUB_APP_ID")
      ENV.delete("GITHUB_APP_PRIVATE_KEY")
      ENV.delete("GITHUB_APP_INSTALLATION_ID")
      Rails.cache.clear
    end

    context "when app is not configured" do
      before do
        ENV["GITHUB_APP_ID"] = nil
      end

      it "raises an error" do
        expect {
          described_class.installation_token_for { remote_url }
        }.to raise_error(Orchestrator::GitHubAppAuth::Error, /not configured/)
      end
    end

    context "when app is configured with installation ID" do
      it "generates and caches a token" do
        allow(Open3).to receive(:capture3).and_call_original
        allow(Open3).to receive(:capture3).with(
          "curl", "-s", "-X", "POST",
          "-H", "Accept: application/vnd.github.v3+json",
          "-H", /Authorization: Bearer/,
          "https://api.github.com/app/installations/#{installation_id}/access_tokens"
        ).and_return(
          [ { token: mock_token }.to_json, "", double(success?: true) ],
          [ { token: "different_token" }.to_json, "", double(success?: true) ]
        )

        token1 = described_class.installation_token_for { remote_url }
        expect(token1).to eq(mock_token)

        # Second call should return cached token
        token2 = described_class.installation_token_for { remote_url }
        expect(token2).to eq(mock_token)
      end
    end

    context "when token generation fails" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ { message: "GitHub error" }.to_json, "error", double(success?: false) ]
        )
      end

      it "raises an error with GitHub API response" do
        expect {
          described_class.installation_token_for { remote_url }
        }.to raise_error(Orchestrator::GitHubAppAuth::Error)
      end
    end
  end
end
