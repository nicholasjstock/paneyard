require "rails_helper"

RSpec.describe McpTools::RunPresenter do
  it "gives MCP callers a run's checkpoint reports, oldest first" do
    run, session = create_run_and_session(prefix: "presenter")
    run.checkpoints.create!(run_session: session, outcome: "blocked", summary: "Which migration?", created_at: 2.minutes.ago)
    run.checkpoints.create!(run_session: session, outcome: "done", summary: "Dropped the table.", created_at: 1.minute.ago)

    checkpoints = described_class.detail(run.reload)[:checkpoints]

    expect(checkpoints.map { |checkpoint| checkpoint.slice(:outcome, :summary) }).to eq([
      { outcome: "blocked", summary: "Which migration?" },
      { outcome: "done", summary: "Dropped the table." }
    ])
  end
end
