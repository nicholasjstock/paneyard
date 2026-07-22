require "rails_helper"

RSpec.describe Orchestrator::ProjectInitTrigger do
  it "creates a blocking, read-only project_init request scoped to the workspace's lineage" do
    run = create_run

    described_class.call(run: run)

    request = run.spawn_requests.find_by!(requested_role: "project_init")
    assert_equal "blocking", request.priority
    assert_equal "diagnosis", request.execution_mode
    assert_equal "source_protected", request.write_scope
    assert_equal "project-init:#{run.workspace_id}", request.lineage_key
  end

  it "does not create a second request when the primary entry already exists" do
    run = create_run
    record_primary_entry(run)

    described_class.call(run: run)

    assert_nil run.spawn_requests.find_by(requested_role: "project_init")
  end

  it "does not create a duplicate request while one is already open" do
    run = create_run
    described_class.call(run: run)

    assert_difference -> { run.spawn_requests.count }, 0 do
      described_class.call(run: run)
    end
  end

  it "force bypasses the existing-entry check" do
    run = create_run
    record_primary_entry(run)

    described_class.call(run: run, force: true)

    assert run.spawn_requests.find_by(requested_role: "project_init")
  end

  def record_primary_entry(run)
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: described_class::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )
  end

  def create_run
    root = Dir.mktmpdir("project-init-trigger")
    workspace = Workspace.create!(name: "project-init-trigger-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "project-init-trigger-#{SecureRandom.hex(4)}", task: "Exercise project init trigger",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
