require "rails_helper"

RSpec.describe McpTools::ListModelsTool do
  before { Rails.cache.clear }

  it "lists what the driver's CLI offers on the workspace's runner, with the model a run gets by default" do
    workspace = create_workspace(prefix: "list-models")
    allow(Orchestrator::Runner::ModelDiscovery).to receive(:models_for).with("claude")
      .and_return([ { "id" => "claude-sonnet-5-5", "label" => "Sonnet 5.5 — claude-sonnet-5-5" } ])

    response = described_class.call(driver: "claude", workspace: workspace.name, server_context: {})

    expect(response.structured_content).to eq(driver: "claude", defaultModel: "opus",
      models: [ { id: "claude-sonnet-5-5", label: "Sonnet 5.5 — claude-sonnet-5-5" } ])
  end

  it "says codex runs on its own configured default, and lists nothing when the CLI offers nothing" do
    create_workspace(prefix: "list-models-codex")
    allow(Orchestrator::Runner::ModelDiscovery).to receive(:models_for).with("codex").and_return([])

    response = described_class.call(driver: "codex", server_context: {})

    expect(response.structured_content).to eq(driver: "codex", defaultModel: nil, models: [])
  end

  it "refuses a driver it does not launch" do
    response = described_class.call(driver: "opencode", server_context: {})

    expect(response.error?).to be(true)
  end
end
