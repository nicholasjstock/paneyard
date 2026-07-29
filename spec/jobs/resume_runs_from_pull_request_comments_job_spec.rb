require "rails_helper"

RSpec.describe ResumeRunsFromPullRequestCommentsJob do
  it "picks up a run that only has a conversation issue, with no PR yet" do
    workspace = Workspace.create!(name: "job-issue-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "job-issue-#{SecureRandom.hex(4)}", task: "Approve the plan", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "job-issue-a1b2", branch_name: "workflow/job-issue-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open"
    )

    allow(Orchestrator::PullRequestResume).to receive(:comments_after).with(run).and_return([])

    described_class.perform_now

    expect(Orchestrator::PullRequestResume).to have_received(:comments_after).with(run)
  end

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

  it "continues scanning after a deleted conversation to process a later run" do
    workspace = Workspace.create!(name: "job-deleted-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    deleted_run = workspace.runs.create!(
      run_id: "job-deleted-#{SecureRandom.hex(4)}", task: "Deleted issue", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "job-deleted-a1b2", branch_name: "workflow/job-deleted-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open"
    )
    later_run = workspace.runs.create!(
      run_id: "job-later-#{SecureRandom.hex(4)}", task: "Later issue", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "job-later-a1b2", branch_name: "workflow/job-later-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/39", github_issue_status: "open"
    )
    comment = { "id" => 39, "body" => "Continue", "user" => { "login" => "operator" } }
    allow(Orchestrator::PullRequestResume).to receive(:comments_after).with(deleted_run).and_return([])
    allow(Orchestrator::PullRequestResume).to receive(:comments_after).with(later_run).and_return([ comment ])
    allow(Orchestrator::PullRequestResume).to receive(:resume!)

    described_class.perform_now

    expect(Orchestrator::PullRequestResume).to have_received(:resume!).with(later_run, comment)
  end
end
