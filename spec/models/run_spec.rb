require "rails_helper"

RSpec.describe Run, type: :model do
  it "renders stale launching runs as launch queued" do
    workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("workflow-run-model"))
    run = Run.create!(
      run_id: "demo-#{SecureRandom.hex(4)}",
      task: "Check stale launch rendering",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "launching",
      launched_by: "operator",
      created_at: 2.minutes.ago,
      updated_at: 2.minutes.ago
    )

    expect(run.launch_queued?).to be(true)
    expect(run.status_badge_label).to eq("launch queued")
    expect(run.status_badge_class).to eq("queued")
  end

  it "does not emit duplicate status events for an unchanged phase" do
    workspace = Workspace.create!(name: "status-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("workflow-status"))
    run = Run.create!(
      run_id: "demo-#{SecureRandom.hex(4)}", task: "Deduplicate status", workspace:,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )

    run.publish_phase!(phase: "waiting_on_capacity", owner: "orchestrator", summary: "Retry at noon.")
    first_updated_at = run.phase_updated_at
    run.publish_phase!(phase: "waiting_on_capacity", owner: "orchestrator", summary: "Retry at noon.")

    expect(run.bus_events.where(event_type: "run.status").count).to eq(1)
    expect(run.reload.phase_updated_at).to eq(first_updated_at)
  end
end
