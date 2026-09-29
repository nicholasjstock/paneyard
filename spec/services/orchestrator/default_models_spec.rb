require "rails_helper"

RSpec.describe Orchestrator::DefaultModels do
  around do |example|
    saved = ENV.to_h.slice("WORKFLOW_CLAUDE_MODEL", "WORKFLOW_CODEX_MODEL", "WORKFLOW_OPENCODE_MODEL")
    %w[WORKFLOW_CLAUDE_MODEL WORKFLOW_CODEX_MODEL WORKFLOW_OPENCODE_MODEL].each { |name| ENV.delete(name) }
    example.run
  ensure
    %w[WORKFLOW_CLAUDE_MODEL WORKFLOW_CODEX_MODEL WORKFLOW_OPENCODE_MODEL].each { |name| ENV.delete(name) }
    ENV.update(saved)
  end

  it "defaults claude to opus and leaves codex and opencode to their own configured model" do
    expect(described_class.for("claude")).to eq("opus")
    expect(described_class.for("codex")).to be_nil
    expect(described_class.for("opencode")).to be_nil
  end

  it "takes a per-driver override from the environment" do
    ENV["WORKFLOW_CODEX_MODEL"] = "some-codex-model"
    ENV["WORKFLOW_OPENCODE_MODEL"] = "provider/some-model"

    expect(described_class.for("codex")).to eq("some-codex-model")
    expect(described_class.for("opencode")).to eq("provider/some-model")
  end
end
