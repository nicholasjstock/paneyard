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
end
