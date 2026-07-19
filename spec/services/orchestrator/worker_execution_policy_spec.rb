require "rails_helper"

RSpec.describe Orchestrator::WorkerExecutionPolicy do
  it "keeps an artifact-only target read-only while retaining Bash" do
    root = Dir.mktmpdir("artifact-policy")
    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "artifact_only", allowed_paths: []
    )

    expect(policy.claude_tools.split(",")).to include("Bash")
    expect(policy.claude_tools.split(",")).not_to include("Edit", "Write")
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to eq([])
    expect(policy.codex_config_overrides.join(" ")).to include('"."="read"')
  end

  it "rejects repository grants for artifact-only workers" do
    root = Dir.mktmpdir("artifact-policy")

    expect do
      described_class.new(
        root_dir: root, mode: "diagnosis", write_scope: "artifact_only",
        allowed_paths: [ "Gemfile.lock" ]
      )
    end.to raise_error(ArgumentError, /artifact_only workers cannot authorize/)
  end

  it "rejects absolute, ambiguous, and escaping paths" do
    root = Dir.mktmpdir("scoped-policy")

    [ "/tmp/file", "front/**/*.ts", "../outside" ].each do |path|
      expect do
        described_class.new(
          root_dir: root, mode: "implementation", write_scope: "scoped_changes",
          allowed_paths: [ path ]
        )
      end.to raise_error(ArgumentError)
    end
  end
end
