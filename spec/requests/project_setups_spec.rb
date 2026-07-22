require "rails_helper"

RSpec.describe "project setups", type: :request do
  it "re-triggers project init against the workspace's active run" do
    workspace, run = create_workspace_with_active_run

    post workspace_project_setup_path(workspace)

    expect(response).to redirect_to(workspace_runs_path(workspace))
    request = run.spawn_requests.find_by(requested_role: "project_init")
    expect(request).to be_present
  end

  it "launches a bootstrap run when the workspace has no active run to piggyback on" do
    workspace = Workspace.create!(name: "project-setup-request-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)

    expect do
      post workspace_project_setup_path(workspace)
    end.to change { workspace.runs.count }.by(1)

    expect(response).to redirect_to(workspace_runs_path(workspace))
    run = workspace.runs.order(:created_at).last
    expect(run.launched_by).to eq("workspace_init")
    expect(run.spawn_requests.find_by(requested_role: "project_init")).to be_present
  end

  def create_workspace_with_active_run
    root = Dir.mktmpdir("project-setup-request")
    workspace = Workspace.create!(name: "project-setup-request-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "project-setup-request-#{SecureRandom.hex(4)}", task: "Exercise manual project setup re-trigger",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    [ workspace, run ]
  end
end
