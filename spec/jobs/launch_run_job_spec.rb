require "rails_helper"

RSpec.describe LaunchRunJob do
  it "seeds a project_init request on a workspace's first run" do
    run = create_launching_run
    allow(Orchestrator::GitWorktree).to receive(:provision!).with(run).and_return(run)

    LaunchRunJob.perform_now(run.id)

    assert_equal "running", run.reload.status
    request = run.spawn_requests.find_by(requested_role: "project_init")
    assert request
    assert_equal "blocking", request.priority
    assert_equal "diagnosis", request.execution_mode
    assert_equal "source_protected", request.write_scope
  end

  it "does not seed a second project_init request once the workspace already has one recorded" do
    run = create_launching_run
    allow(Orchestrator::GitWorktree).to receive(:provision!).with(run).and_return(run)
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )

    LaunchRunJob.perform_now(run.id)

    assert_nil run.reload.spawn_requests.find_by(requested_role: "project_init")
  end

  it "provisions a dedicated worktree before starting task orchestration" do
    run = create_launching_run

    expect(Orchestrator::GitWorktree).to receive(:provision!).with(run).ordered.and_return(run)
    expect(Orchestrator::ProjectInitTrigger).to receive(:call).with(run: run).ordered

    LaunchRunJob.perform_now(run.id)
  end

  def create_launching_run
    root = Dir.mktmpdir("launch-run-job")
    workspace = Workspace.create!(name: "launch-run-job-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "launch-run-job-#{SecureRandom.hex(4)}", task: "Exercise launch", target_root: root,
      launcher_variant: "claude", status: "launching", launched_by: "operator"
    )
  end
end
