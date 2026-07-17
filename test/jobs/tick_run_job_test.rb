require "test_helper"

class TickRunJobTest < ActiveSupport::TestCase
  test "does not overwrite a planner decision while fulfilling its worker request" do
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

  test "requests one recovery planner after a real dead end without writing tick state" do
    workspace = Workspace.create!(name: "tick-recovery-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-recovery-#{SecureRandom.hex(4)}", task: "Recover work",
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
    assert_includes request.text, "Inspect this recovery context"
    assert_equal state, Orchestrator::TickState.latest(run.run_id)
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
