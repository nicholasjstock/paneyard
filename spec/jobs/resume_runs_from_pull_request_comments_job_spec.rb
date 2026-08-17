require "rails_helper"

RSpec.describe ResumeRunsFromPullRequestCommentsJob do
  it "skips a merged run even if it still has a conversation url" do
    workspace = Workspace.create!(name: "job-merged-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "job-merged-#{SecureRandom.hex(4)}", task: "Already merged", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "job-merged-a1b2", branch_name: "workflow/job-merged-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "merged"
    )

    allow(Orchestrator::PullRequestResume).to receive(:comments_after)

    described_class.perform_now

    expect(Orchestrator::PullRequestResume).not_to have_received(:comments_after).with(run)
  end

  it "skips a run with neither a PR nor an issue" do
    workspace = Workspace.create!(name: "job-none-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "job-none-#{SecureRandom.hex(4)}", task: "No conversation yet", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", worktree_name: "job-none-a1b2", branch_name: "workflow/job-none-a1b2"
    )

    allow(Orchestrator::PullRequestResume).to receive(:comments_after)

    described_class.perform_now

    expect(Orchestrator::PullRequestResume).not_to have_received(:comments_after).with(run)
  end
end
