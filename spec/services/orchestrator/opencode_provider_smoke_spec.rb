require "rails_helper"

RSpec.describe "open code provider smoke", :live_agent do
  it "runs a single turn through the opencode CLI" do
    skip "opencode is not installed" unless system("which opencode >/dev/null 2>&1")

    Dir.mktmpdir("opencode-provider-smoke") do |dir|
      chat = double("AdminChat")
      events = []

      result = Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider.run_turn(
        workspace_path: dir,
        prompt: "Say hello back, one word only.",
        session_id: nil,
        model: Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider::DEFAULT_MODEL
      ) { |event| events << event }

      expect(result[:error]).to eq(false), "stderr=#{result[:stderr]}"
      expect(result[:cancelled]).to eq(false)
      expect(result[:session_id]).to be_present

      expect(events).to include(hash_including(type: "session_started"))
      expect(events).to include(hash_including(type: "turn_completed"))
    end
  end

  it "resumes an existing session" do
    skip "opencode is not installed" unless system("which opencode >/dev/null 2>&1")

    Dir.mktmpdir("opencode-provider-smoke") do |dir|
      session_id = nil
      Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider.run_turn(
        workspace_path: dir,
        prompt: "Say hello.",
        session_id: nil,
        model: Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider::DEFAULT_MODEL
      ) { |event| session_id = event[:session_id] if event[:type] == "session_started" }

      skip "No session was created" if session_id.blank?

      events = []
      result = Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider.run_turn(
        workspace_path: dir,
        prompt: "Say goodbye.",
        session_id: session_id,
        model: Orchestrator::WorkspaceAdminChatDriver::OpenCodeProvider::DEFAULT_MODEL
      ) { |event| events << event }

      expect(result[:error]).to be false
      expect(result[:session_id]).to eq(session_id)
      expect(events).to include(hash_including(type: "turn_completed"))
    end
  end
end
