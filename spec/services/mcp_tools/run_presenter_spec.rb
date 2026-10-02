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

  describe "follow-ups" do
    let(:workspace) { create_workspace(prefix: "presenter") }
    let!(:parent) { create_run(workspace:, prefix: "parent", status: "completed", branch_name: "paneyard/parent-7efb") }
    let!(:child) { create_run(workspace:, prefix: "child", status: "queued", base_branch: "paneyard/parent-7efb") }
    let!(:unrelated) { create_run(workspace:, prefix: "plain", status: "queued") }

    it "names a follow-up's parent: the run whose branch it started from, in its workspace" do
      elsewhere = create_run(prefix: "elsewhere", status: "queued", base_branch: "paneyard/parent-7efb")
      runs = [ parent, child, unrelated, elsewhere ]

      parents = described_class.parent_run_ids(runs)

      expect(runs.map { |run| described_class.summary(run, parents:)[:parent_run_id] }).to eq([ nil, parent.run_id, nil, nil ])
      expect(described_class.summary(child)[:parent_run_id]).to eq(parent.run_id)
    end

    it "lists a run's follow-ups, and whether its closed session could be reopened" do
      allow(Orchestrator::Runner.local).to receive(:worktree_registered?).and_return(false)
      allow(Orchestrator::Runner.local).to receive(:branch_exists?).and_return(false)

      detail = described_class.detail(parent)

      expect(detail[:follow_up_run_ids]).to eq([ child.run_id ])
      expect(detail).to include(reopenable: false, reopen_problem: include("no longer exists"))
      expect(described_class.detail(unrelated)).to include(follow_up_run_ids: [], reopenable: false)
      expect(described_class.detail(unrelated)).not_to have_key(:reopen_problem)
    end
  end
end
