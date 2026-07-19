require "rails_helper"

RSpec.describe LaunchRunJob do
  it "seeds a project_init request on a workspace's first run" do
    run = create_launching_run

    LaunchRunJob.perform_now(run.id)

    assert_equal "running", run.reload.status
    request = run.spawn_requests.find_by(requested_role: "project_init")
    assert request
    assert_equal "blocking", request.priority
    assert_equal "diagnosis", request.execution_mode
    assert_equal "artifact_only", request.write_scope
  end

  it "does not seed a second project_init request once the workspace already has one recorded" do
    run = create_launching_run
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )

    LaunchRunJob.perform_now(run.id)

    assert_nil run.reload.spawn_requests.find_by(requested_role: "project_init")
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
