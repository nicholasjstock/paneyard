require "rails_helper"

RSpec.describe "worker persona docs" do
  let(:claude_doc) { File.read(Rails.root.join(".claude/agents/worker.md")) }
  let(:codex_doc) { File.read(Rails.root.join(".codex/agents/worker.toml")) }
  let(:identity_prompt) { File.read(Rails.root.join("app/services/orchestrator/worker_spawner.rb")) }

  it "no longer instructs workers to detach a long-running command with &" do
    expect(claude_doc).not_to match(/2>&1 &/)
    expect(codex_doc).not_to match(/2>&1 &/)
  end

  it "tells workers to use start_run_command for anything that must outlive this turn" do
    [ claude_doc, codex_doc, identity_prompt ].each do |doc|
      expect(doc).to include("start_run_command")
    end
  end
end
