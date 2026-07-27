require "rails_helper"

RSpec.describe "runs", type: :request do
  it "blocks launching a new run while the workspace is not yet initialized" do
    workspace = Workspace.create!(name: "runs-controller-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)

    get new_workspace_run_path(workspace)
    expect(response).to redirect_to(workspace_runs_path(workspace))
    follow_redirect!
    expect(response.body).to include("still initializing")

    expect do
      post workspace_runs_path(workspace), params: { run: { task: "Do something", launcher_variant: "claude" } }
    end.not_to change(Run, :count)
    expect(response).to redirect_to(workspace_runs_path(workspace))
  end

  it "allows launching a new run once the workspace has declared protected paths" do
    workspace = Workspace.create!(
      name: "runs-controller-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir,
      protected_path_patterns: [ "app/controllers/**/*.rb" ]
    )

    get new_workspace_run_path(workspace)
    expect(response).to have_http_status(:ok)

    expect do
      post workspace_runs_path(workspace), params: { run: { task: "Do something", launcher_variant: "claude" } }
    end.to change(Run, :count).by(1)

    run = workspace.runs.order(:created_at).last
    expect(run.worktree_name).to start_with("do-something-")
    expect(run.target_root).to eq(workspace.source_root)
  end

  # Regression: run-20260727-165215-d272 had a worktree_name (assigned
  # eagerly at creation) but never a real provisioned worktree, since
  # GitWorktree.provision! failed first. publication_retryable? now checks
  # branch_name, so the button itself would not appear for that exact case --
  # this exercises the deeper defense: even if reached directly, the
  # controller must not spawn the git worker against a broken target_root,
  # and must not leave the run stuck at status "running" with nothing in flight.
  it "does not spawn the git worker or leave the run running when its target_root is missing" do
    workspace = Workspace.create!(name: "runs-controller-retry-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "runs-controller-retry-#{SecureRandom.hex(4)}", task: "Retry a broken worktree",
      target_root: File.join(workspace.root_path, "missing-worktree"), launcher_variant: "codex",
      status: "failed", worktree_name: "broken-a1b2", branch_name: "workflow/broken-a1b2",
      publication_status: "failed"
    )

    expect do
      post retry_publication_workspace_run_path(workspace, run)
    end.not_to change(SpawnRequest, :count)

    follow_redirect!
    expect(response.body).to include("Could not retry publication")
    expect(run.reload).to have_attributes(status: "failed", publication_status: "failed")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end
end
