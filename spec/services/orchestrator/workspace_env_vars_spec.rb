require "rails_helper"

RSpec.describe Orchestrator::WorkspaceEnvVars do
  it "records an env var and makes it retrievable as a workspace-wide hash" do
    workspace = Workspace.create!(name: "env-vars-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "env-vars-run-#{SecureRandom.hex(4)}", task: "Env var test",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )

    Orchestrator::WorkspaceEnvVars.record!(
      run_id: run.run_id, name: "BUNDLE_WITHOUT", value: "production", evidence_ref: "worker.log:42",
      recorded_by: "worker"
    )

    expect(Orchestrator::WorkspaceEnvVars.for_workspace(workspace)).to eq("BUNDLE_WITHOUT" => "production")
  end

  it "overwrites the value in place when the same name is recorded again, without keeping supersede history" do
    workspace = Workspace.create!(name: "env-vars-overwrite-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "env-vars-overwrite-run-#{SecureRandom.hex(4)}", task: "Env var test",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )

    Orchestrator::WorkspaceEnvVars.record!(
      run_id: run.run_id, name: "NOKOGIRI_USE_SYSTEM_LIBRARIES", value: "0", evidence_ref: "a.log", recorded_by: "worker"
    )
    Orchestrator::WorkspaceEnvVars.record!(
      run_id: run.run_id, name: "NOKOGIRI_USE_SYSTEM_LIBRARIES", value: "1", evidence_ref: "b.log", recorded_by: "git"
    )

    expect(workspace.workspace_env_vars.count).to eq(1)
    entry = workspace.workspace_env_vars.sole
    expect(entry.value).to eq("1")
    expect(entry.recorded_by).to eq("git")
  end

  it "scopes recorded env vars to their own workspace" do
    workspace_a = Workspace.create!(name: "env-vars-a-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    workspace_b = Workspace.create!(name: "env-vars-b-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run_a = Run.create!(
      workspace: workspace_a, run_id: "env-vars-a-run-#{SecureRandom.hex(4)}", task: "Env var test",
      target_root: workspace_a.root_path, launcher_variant: "claude", status: "running"
    )

    Orchestrator::WorkspaceEnvVars.record!(
      run_id: run_a.run_id, name: "SOME_FLAG", value: "1", evidence_ref: "a.log", recorded_by: "worker"
    )

    expect(Orchestrator::WorkspaceEnvVars.for_workspace(workspace_b)).to eq({})
  end
end
