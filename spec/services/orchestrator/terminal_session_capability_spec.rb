require "rails_helper"

RSpec.describe Orchestrator::TerminalSessionCapability do
  it "authenticates only the session named by the signed capability" do
    workspace = Workspace.create!(name: "capability-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
    session = workspace.create_terminal_session!(launcher_variant: "claude")

    token = Orchestrator::TerminalSessionCapability.issue(session)

    assert_equal session, Orchestrator::TerminalSessionCapability.authenticate(token)
    assert_nil Orchestrator::TerminalSessionCapability.authenticate("not-a-token")
  end
end
