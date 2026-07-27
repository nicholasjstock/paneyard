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

  it "renders persona controls and persists the selected configuration" do
    workspace = Workspace.create!(
      name: "runs-persona-ui-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir,
      protected_path_patterns: [ "app/controllers/**/*.rb" ]
    )

    get new_workspace_run_path(workspace)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("persona-configuration")
    expect(response.body).to include("run[persona_config][finalization_roles][]")
    expect(response.body).to include("run[persona_config][skip_roles][]")

    post workspace_runs_path(workspace), params: {
      run: {
        task: "Use selected personas",
        launcher_variant: "claude",
        persona_config: {
          finalization_roles: %w[demo reporter],
          skip_roles: %w[verifier curator]
        }
      }
    }

    expect(response).to have_http_status(:redirect)
    run = workspace.runs.order(:created_at).last
    expect(run.finalization_roles).to eq(%w[demo reporter])
    expect(run.skip_roles).to eq(%w[verifier curator])
  end
end
