require "rails_helper"

RSpec.describe Orchestrator::SwitchRunLauncher do
  include ActiveJob::TestHelper

  it "switches a capacity-paused idle run, preserves its queued handoffs, and schedules a tick" do
    run = build_run
    run.update!(capacity_available_at: 30.minutes.from_now)
    request = run.spawn_requests.create!(
      asked_by: "chaperone", requested_role: "chaperone", scope: "criterion:demo",
      lineage_key: "criterion:demo", text: "Review repeated failures.", priority: "blocking", model_tier: "strong"
    )

    assert_enqueued_with(job: TickRunJob) do
      described_class.call(run:, launcher_variant: "codex")
    end

    run.reload
    assert_equal "codex", run.launcher_variant
    assert_nil run.capacity_available_at
    assert_equal "planning", run.phase
    assert_equal "operator", run.phase_owner
    assert_match(/Switched to Codex/, run.phase_summary)
    assert_equal "open", request.reload.status
  end

  it "rejects a switch when the run is not capacity-paused" do
    run = build_run

    expect {
      described_class.call(run:, launcher_variant: "codex")
    }.to raise_error(described_class::Ineligible, /not waiting for launcher capacity/)
  end

  it "rejects a switch while work is active" do
    run = build_run
    run.update!(capacity_available_at: 30.minutes.from_now)
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "active", reason: "Working.", scope: "work.md",
      status: "running", pid: 123_456, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp", "active.prompt").to_s,
      log_path: Rails.root.join("tmp", "active.log").to_s,
      last_message_path: Rails.root.join("tmp", "active.last").to_s,
      env_path: Rails.root.join("tmp", "active.env").to_s
    )

    expect {
      described_class.call(run:, launcher_variant: "codex")
    }.to raise_error(described_class::Ineligible, /worker is still active/)
  end

  private

  def build_run
    workspace = Workspace.create!(name: "switch-launcher-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.runs.create!(
      run_id: "switch-launcher-#{SecureRandom.hex(4)}", task: "Resume with another launcher",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
  end
end
