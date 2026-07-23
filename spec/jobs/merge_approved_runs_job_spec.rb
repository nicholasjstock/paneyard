require "rails_helper"

RSpec.describe MergeApprovedRunsJob do
  it "does nothing while a PR is merely awaiting approval" do
    run = create_published_run(publication_status: "awaiting_approval")
    allow(Orchestrator::RunPublication).to receive(:merged?).with(run).and_return(false)

    expect(Orchestrator::RunPublication).not_to receive(:cleanup_merged_run!)

    described_class.perform_now
  end

  it "cleans evidence and the worktree only after GitHub reports a merged PR" do
    run = create_published_run(publication_status: "published")
    allow(Orchestrator::RunPublication).to receive(:merged?).with(run).and_return(true)

    expect(Orchestrator::RunPublication).to receive(:cleanup_merged_run!).with(run)

    described_class.perform_now
  end

  it "cleans legacy evidence-cleanup runs after their PR is manually merged" do
    run = create_published_run(publication_status: "cleanup_pushed")
    allow(Orchestrator::RunPublication).to receive(:merged?).with(run).and_return(true)

    expect(Orchestrator::RunPublication).to receive(:cleanup_merged_run!).with(run)

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
