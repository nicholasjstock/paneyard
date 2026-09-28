require "rails_helper"

RSpec.describe Orchestrator::ModelCatalog do
  let(:workspace) { Workspace.new(name: "catalog") }

  it "offers what the workspace's runner says its CLIs can run" do
    allow(Orchestrator::Runner.local).to receive(:available_models)
    allow(Orchestrator::Runner.local).to receive(:available_models).with("claude")
      .and_return([ { "id" => "claude-sonnet-5", "label" => "Sonnet 5 — claude-sonnet-5" } ])

    expect(described_class.all(workspace)).to eq(
      "claude" => [ { "id" => "claude-sonnet-5", "label" => "Sonnet 5 — claude-sonnet-5" } ],
      "codex" => [], "opencode" => []
    )
  end

  it "caches a runner's answer, per runner, so the form does not run every CLI on each render" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Orchestrator::Runner.local).to receive(:available_models).with("codex")
      .and_return([ { "id" => "gpt-5.5", "label" => "gpt-5.5" } ])

    2.times { expect(described_class.options_for("codex", workspace).pluck("id")).to eq([ "gpt-5.5" ]) }

    expect(Orchestrator::Runner.local).to have_received(:available_models).once
    expect(Rails.cache.exist?("orchestrator/model_catalog/local/codex")).to be(true)
  end
end
