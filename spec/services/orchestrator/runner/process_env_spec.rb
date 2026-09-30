require "rails_helper"

RSpec.describe Orchestrator::Runner::ProcessEnv do
  before do
    allow(described_class).to receive(:sanitized_process_env).and_return("RAILS_ENV" => nil, "SHARED" => "process")
    allow(described_class).to receive(:gh_auth_token).and_return("gho_ambient")
  end

  def env_for(**overrides)
    described_class.for_session(
      workspace_env: { "SHARED" => "workspace", "PANEYARD_RUN_ID" => "spoofed", "ONLY_WORKSPACE" => "1" },
      env: { "PANEYARD_RUN_ID" => "run-1" }, capability_token: "tok", github_token: nil,
      ambient_github_auth: true, extra: { "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1" }, **overrides
    )
  end

  it "layers workspace vars under the process env, the run's identity, git credentials and driver extras" do
    env = env_for

    expect(env).to include(
      "ONLY_WORKSPACE" => "1", "SHARED" => "process", "RAILS_ENV" => nil,
      "PANEYARD_RUN_ID" => "run-1", "PANEYARD_RUN_TOKEN" => "tok",
      "GH_TOKEN" => "gho_ambient", "GIT_TERMINAL_PROMPT" => "0",
      "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"
    )
  end

  it "prefers the orchestrator's installation token over this machine's gh auth" do
    expect(env_for(github_token: "ghs_app")).to include("GH_TOKEN" => "ghs_app")
    expect(described_class).not_to have_received(:gh_auth_token)
  end

  it "hands out no git credentials when ambient auth is not allowed and no token came" do
    env = env_for(ambient_github_auth: false)

    expect(env.keys).not_to include("GH_TOKEN", "GIT_CONFIG_COUNT")
    expect(described_class).not_to have_received(:gh_auth_token)
  end
end
