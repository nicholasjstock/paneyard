require "rails_helper"

RSpec.describe TickRunJob do
  it "does not overwrite a planner decision while fulfilling its worker request" do
    workspace = Workspace.create!(name: "tick-job-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-job-#{SecureRandom.hex(4)}", task: "Test scheduler boundary",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    planned_state = Orchestrator::TickState.write(
      run_id: run.run_id, phase: "planning", tick_count: 1, last_plan_summary: "Planner chose the next step.",
      pending_spawn_keys: [ "worker-report" ], following_steps: [ { owner: "worker", artifact: "verify.md", success_check: "verify" } ]
    )
    SpawnRequest.create!(
      run_id: run.run_id, asked_by: "planner", scope: "fix.md", text: "Implement the fix.",
      requested_role: "worker", priority: "blocking"
    )

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    assert_equal planned_state, Orchestrator::TickState.latest(run.run_id)
  end

  it "requests one recovery planner after a real dead end without writing tick state" do
    workspace = Workspace.create!(name: "tick-recovery-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-recovery-#{SecureRandom.hex(4)}", task: "Recover work that may need a fix",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    state = Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1, last_plan_summary: "Worker was assigned.",
      pending_spawn_keys: [], following_steps: []
    )

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    request = SpawnRequest.open_only.find_by!(run_id: run.run_id, requested_role: "planner")
    assert_includes request.text, "Inspect the recovery evidence"
    assert_includes request.text, "Evidence references:"
    assert_includes request.context, "Recover work that may need a fix"
    assert_equal state, Orchestrator::TickState.latest(run.run_id)
  end

  it "clears an expired capacity phase when work is active" do
    workspace = Workspace.create!(name: "tick-capacity-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-capacity-#{SecureRandom.hex(4)}", task: "Resume after capacity",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      phase: "waiting_on_capacity", phase_summary: "Capacity unavailable.", capacity_available_at: 1.minute.ago
    )
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "planner", nickname: "planner-live", reason: "Recover the run.",
      scope: "workflow-plan.md", status: "running", pid: 123_456, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/planner-live.prompt.txt").to_s,
      log_path: Rails.root.join("tmp/planner-live.log").to_s,
      last_message_path: Rails.root.join("tmp/planner-live.last-message.txt").to_s,
      env_path: Rails.root.join("tmp/planner-live.env.json").to_s
    )

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    assert_equal "waiting_on_workers", run.reload.phase
    assert_equal "planner", run.phase_owner
    assert_equal "planner-live is active on workflow-plan.md.", run.phase_summary
  end

  private

  def without_spawning_workers
    singleton = Orchestrator::SpawnRequestedWorkers.singleton_class
    original = singleton.instance_method(:call)
    singleton.define_method(:call) { |run:| [] }
    yield
  ensure
    singleton&.define_method(:call, original) if original
  end
end
