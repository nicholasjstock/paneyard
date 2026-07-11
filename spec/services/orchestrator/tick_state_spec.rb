require "rails_helper"

RSpec.describe Orchestrator::TickState do
  it "syncs the latest tick phase back onto the run row" do
    workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("workflow-tick-state"))
    run = Run.create!(
      run_id: "demo-#{SecureRandom.hex(4)}",
      task: "Sync run state from ticks",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      phase: "starting",
      phase_owner: "orchestrator",
      phase_summary: "Opening orchestrator phase."
    )

    described_class.write(
      run_id: run.run_id,
      phase: "waiting_on_workers",
      tick_count: 1,
      last_plan_summary: "Cut the phone demo pauses roughly in half.",
      pending_spawn_keys: [],
      following_steps: [],
      last_updated_at: Time.current.iso8601
    )

    expect(run.reload.phase).to eq("waiting_on_workers")
    expect(run.phase_owner).to eq("worker")
    expect(run.phase_summary).to eq("Cut the phone demo pauses roughly in half.")
  end
end
