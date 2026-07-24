require "rails_helper"

RSpec.describe TerminalSessionReconcileJob do
  it "reconciles every active terminal session and leaves exited ones alone" do
    active = create_session(status: "running")
    exited = create_session(status: "exited")

    expect(Orchestrator::TerminalSessionRunner).to receive(:reconcile!).with(active)

    described_class.perform_now
  end

  def create_session(status:)
    workspace = Workspace.create!(name: "terminal-reconcile-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.create_terminal_session!(launcher_variant: "claude", status:)
  end
end
