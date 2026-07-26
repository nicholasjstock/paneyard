require "rails_helper"

RSpec.describe FinalizeRunPublicationJob do
  it "opens exactly one blocking review question when the PR is published" do
    workspace = Workspace.create!(name: "finalize-publish-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "finalize-publish-#{SecureRandom.hex(4)}", task: "Finalize with a PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", worktree_name: "finalize-a1b2", branch_name: "workflow/finalize-a1b2"
    )
    allow(Orchestrator::RunPublication).to receive(:publish!) do
      run.update!(pull_request_url: "https://github.com/example/repo/pull/42")
      :published
    end

    FinalizeRunPublicationJob.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
    question = run.user_questions.open_only.where(priority: "blocking").sole
    expect(question).to have_attributes(asked_by: "orchestrator", scope: "pull_request_review")
  end

  it "does not open a second review question on a retried finalization" do
    workspace = Workspace.create!(name: "finalize-retry-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "finalize-retry-#{SecureRandom.hex(4)}", task: "Finalize twice", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", worktree_name: "finalize-retry-a1b2", branch_name: "workflow/finalize-retry-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42"
    )
    allow(Orchestrator::RunPublication).to receive(:publish!).and_return(:published)

    FinalizeRunPublicationJob.perform_now(run.id)
    FinalizeRunPublicationJob.perform_now(run.id)

    expect(run.user_questions.open_only.where(priority: "blocking").count).to eq(1)
  end

  it "does not open a review question when there were no source changes to publish" do
    workspace = Workspace.create!(name: "finalize-no-changes-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "finalize-no-changes-#{SecureRandom.hex(4)}", task: "Finalize with no changes", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", worktree_name: "finalize-no-changes-a1b2", branch_name: "workflow/finalize-no-changes-a1b2"
    )
    allow(Orchestrator::RunPublication).to receive(:publish!).and_return(:no_changes)

    FinalizeRunPublicationJob.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
    expect(run.user_questions).to be_empty
  end

  it "queues a source worker instead of declaring a conflicted branch ready for review" do
    workspace = Workspace.create!(name: "finalize-merge-conflict-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "finalize-merge-conflict-#{SecureRandom.hex(4)}", task: "Resolve merge conflict", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "merge-conflict-a1b2", branch_name: "workflow/merge-conflict-a1b2"
    )
    allow(Orchestrator::RunPublication).to receive(:publish!).and_return(:merge_conflict)
    allow(Orchestrator::MergeConflictResolution).to receive(:queue_worker!)

    FinalizeRunPublicationJob.perform_now(run.id)

    expect(Orchestrator::MergeConflictResolution).to have_received(:queue_worker!).with(run)
    expect(run.reload.status).to eq("completed")
    expect(run.user_questions).to be_empty
  end
end
