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

  it "stops its own active run commands when it reaches a terminal status, without touching another run's" do
    workspace = Workspace.create!(name: "cleanup-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("workflow-cleanup"))
    run = workspace.runs.create!(
      run_id: "cleanup-#{SecureRandom.hex(4)}", task: "Stop active commands on completion", workspace:,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    other_run = workspace.runs.create!(
      run_id: "other-#{SecureRandom.hex(4)}", task: "Unrelated run", workspace:,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/sleep", arguments: [ "30" ]
    )
    other_command = Orchestrator::RunCommandRunner.start(
      run: other_run, requested_by_worker_id: "worker-2", executable: "/bin/sleep", arguments: [ "30" ]
    )

    run.update!(status: "completed", stopped_at: Time.current)

    expect(command.reload.status).to eq("stopped")
    expect(other_command.reload.status).to eq("running")
  ensure
    Orchestrator::RunCommandRunner.stop(command: other_command, reason: "test cleanup") if other_command
  end

  describe "persona configuration" do
    let(:workspace) { Workspace.create!(name: "persona-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("workflow-persona")) }

    it "defaults to all finalization roles when no persona_config is set" do
      run = Run.create!(
        run_id: "persona-default-#{SecureRandom.hex(4)}", task: "Test persona defaults", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running"
      )

      expect(run.finalization_roles).to eq(%w[seeder reporter curator demo committer])
      expect(run.skip_roles).to eq([])
    end

    it "respects finalization_roles configuration" do
      run = Run.create!(
        run_id: "persona-finalization-#{SecureRandom.hex(4)}", task: "Test finalization override", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        persona_config: { finalization_roles: %w[seeder reporter] }
      )

      expect(run.finalization_roles).to eq(%w[seeder reporter])
    end

    it "respects skip_roles configuration" do
      run = Run.create!(
        run_id: "persona-skip-#{SecureRandom.hex(4)}", task: "Test skip roles", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        persona_config: { skip_roles: %w[curator demo] }
      )

      expect(run.skip_roles).to eq(%w[curator demo])
    end

    it "validates finalization_roles contains only valid roles" do
      run = Run.new(
        run_id: "persona-invalid-finalization-#{SecureRandom.hex(4)}", task: "Test validation", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        persona_config: { finalization_roles: %w[seeder invalid_role] }
      )

      expect(run.valid?).to be(false)
      expect(run.errors[:persona_config]).to include(/contains invalid roles/)
    end

    it "validates skip_roles contains only valid roles" do
      run = Run.new(
        run_id: "persona-invalid-skip-#{SecureRandom.hex(4)}", task: "Test validation", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        persona_config: { skip_roles: %w[worker unknown_role] }
      )

      expect(run.valid?).to be(false)
      expect(run.errors[:persona_config]).to include(/contains invalid roles/)
    end

    it "allows empty finalization_roles to skip all finalization personas" do
      run = Run.create!(
        run_id: "persona-no-finalization-#{SecureRandom.hex(4)}", task: "Skip finalization", workspace:,
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        persona_config: { finalization_roles: [] }
      )

      expect(run.finalization_roles).to eq([])
    end
  end
end
