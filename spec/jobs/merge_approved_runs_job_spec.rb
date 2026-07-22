require "rails_helper"

RSpec.describe MergeApprovedRunsJob do
  it "cleans evidence after GitHub reports an approved review" do
    run = create_published_run(publication_status: "awaiting_approval")
    allow(Orchestrator::RunPublication).to receive(:approved?).with(run).and_return(true)

    expect(Orchestrator::RunPublication).to receive(:remove_evidence!).with(run)

    described_class.perform_now
  end

  it "also watches PRs published before approval tracking was introduced" do
    run = create_published_run(publication_status: "published")
    allow(Orchestrator::RunPublication).to receive(:approved?).with(run).and_return(true)

    expect(Orchestrator::RunPublication).to receive(:remove_evidence!).with(run)

    described_class.perform_now
  end

  it "merges a branch whose approved evidence cleanup was already pushed" do
    run = create_published_run(publication_status: "cleanup_pushed")

    expect(Orchestrator::RunPublication).not_to receive(:approved?)
    expect(Orchestrator::RunPublication).to receive(:merge_and_cleanup!).with(run)

    described_class.perform_now
  end

  def create_published_run(publication_status:)
    workspace = Workspace.create!(name: "approved-merge-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.runs.create!(
      run_id: "approved-merge-#{SecureRandom.hex(4)}", task: "Merge approved PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "merge-approved-a1b2",
      branch_name: "workflow/merge-approved-a1b2", pull_request_url: "https://github.com/example/repo/pull/1",
      publication_status: publication_status
    )
  end
end
