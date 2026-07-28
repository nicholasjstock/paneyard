require "rails_helper"

RSpec.describe "worker persona docs" do
  let(:worker_doc) { File.read(Rails.root.join("agent_personas/worker.md")) }
  let(:identity_prompt) { File.read(Rails.root.join("app/services/orchestrator/worker_spawner.rb")) }

  it "no longer instructs workers to detach a long-running command with &" do
    expect(worker_doc).not_to match(/2>&1 &/)
  end

  it "tells workers to use start_run_command for anything that must outlive this turn" do
    [ worker_doc, identity_prompt ].each do |doc|
      expect(doc).to include("start_run_command")
    end
  end
end
