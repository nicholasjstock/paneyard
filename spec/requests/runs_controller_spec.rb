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
  end
end
