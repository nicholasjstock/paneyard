require "rails_helper"

RSpec.describe TickRunJob do
  it "dispatches an open merge-conflict worker request before waiting for its handoff" do
    workspace = Workspace.create!(name: "tick-merge-conflict-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "tick-merge-conflict-#{SecureRandom.hex(4)}", task: "Resolve conflicts",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running", publication_status: "merge_conflict"
    )
    request = SpawnRequest.create!(
      run_id: run.run_id, asked_by: "orchestrator", requested_role: "worker", priority: "blocking",
      scope: "merge-conflict-resolution.md", text: "Resolve the conflicts.", execution_mode: "implementation",
      write_scope: "scoped_changes", allowed_paths: [ "app/example.rb" ]
    )
    allow(Orchestrator::SpawnRequestedWorkers).to receive(:call)
    allow(Orchestrator::MergeConflictResolution).to receive(:continue_if_ready!)

    TickRunJob.new.send(:tick_run, run)

    expect(Orchestrator::SpawnRequestedWorkers).to have_received(:call).with(run: run)
    expect(Orchestrator::MergeConflictResolution).to have_received(:continue_if_ready!).with(run)
    expect(request.reload.status).to eq("open")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "queues a seeder before the reporter, curator, and committer for a managed run" do
    workspace = Workspace.create!(name: "tick-publish-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace, run_id: "tick-publish-#{SecureRandom.hex(4)}", task: "Publish changes",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running", worktree_name: "publish-changes-a1b2"
    )
    Orchestrator::TickState.write(run_id: run.run_id, phase: "completed", tick_count: 1, last_plan_summary: "Done.", pending_spawn_keys: [], following_steps: [])

    without_spawning_workers do
      expect { TickRunJob.new.send(:tick_run, run) }.not_to have_enqueued_job(FinalizeRunPublicationJob)
    end
    expect(run.reload.status).to eq("running")
    expect(run.publication_status).to eq("commit_pending")
    request = run.spawn_requests.find_by!(requested_role: "seeder")
    expect(request.scope).to eq("seed-data.md")
    expect(request.execution_mode).to eq("implementation")
    expect(request.write_scope).to eq("scoped_changes")
    expect(request.text).to include("seed")
    expect(run.spawn_requests.where(requested_role: %w[reporter curator demo committer])).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "queues a reporter after the seeder completes its handoff, before curator/demo/committer" do
    workspace = Workspace.create!(name: "tick-reporter-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace, run_id: "tick-reporter-#{SecureRandom.hex(4)}", task: "Publish changes",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running", worktree_name: "publish-changes-a1b2"
    )
    Orchestrator::TickState.write(run_id: run.run_id, phase: "completed", tick_count: 1, last_plan_summary: "Done.", pending_spawn_keys: [], following_steps: [])
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "seeder", nickname: "seeder", reason: "Finalize.", scope: "seed-data.md",
      status: "stopped", pid: 123_456, command: "codex", args: [], handoff_completed_at: 1.minute.ago,
      prompt_path: Rails.root.join("tmp/seeder.prompt.txt").to_s, log_path: Rails.root.join("tmp/seeder.log").to_s,
      last_message_path: Rails.root.join("tmp/seeder.last.txt").to_s, env_path: Rails.root.join("tmp/seeder.env").to_s
    )

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    request = run.spawn_requests.find_by!(requested_role: "reporter")
    expect(request.scope).to eq("run-summary.md")
    expect(request.text).to include("get_run_audit")
    expect(request.text).to include("Do not run tests")
    expect(run.spawn_requests.where(requested_role: %w[curator demo committer])).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "queues a demo worker after seeder, reporter, and curator complete their handoffs, before the committer" do
    workspace = Workspace.create!(name: "tick-demo-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace, run_id: "tick-demo-#{SecureRandom.hex(4)}", task: "Publish changes",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running", worktree_name: "publish-changes-a1b2"
    )
    Orchestrator::TickState.write(run_id: run.run_id, phase: "completed", tick_count: 1, last_plan_summary: "Done.", pending_spawn_keys: [], following_steps: [])
    %w[reporter curator seeder].each do |role|
      run.workers.create!(
        worker_id: SecureRandom.uuid, role: role, nickname: role, reason: "Finalize.", scope: "#{role}.md",
        status: "stopped", pid: 123_456, command: "codex", args: [], handoff_completed_at: 1.minute.ago,
        prompt_path: Rails.root.join("tmp/#{role}.prompt.txt").to_s, log_path: Rails.root.join("tmp/#{role}.log").to_s,
        last_message_path: Rails.root.join("tmp/#{role}.last.txt").to_s, env_path: Rails.root.join("tmp/#{role}.env").to_s
      )
    end

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    request = run.spawn_requests.find_by!(requested_role: "demo")
    expect(request.scope).to eq("demo-notes.md")
    expect(request.text).to include("start_run_command")
    expect(run.spawn_requests.where(requested_role: "committer")).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

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

  it "includes the stopped worker artifact in dead-end recovery context" do
    workspace = Workspace.create!(name: "tick-artifact-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-artifact-#{SecureRandom.hex(4)}", task: "Recover from a rejected handoff",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1,
      last_plan_summary: "Worker was assigned.", pending_spawn_keys: [], following_steps: []
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker", reason: "Diagnose.", scope: "diagnosis.md",
      status: "stopped", pid: 123_456, command: "claude", args: [], started_at: 2.minutes.ago, stopped_at: 1.minute.ago,
      prompt_path: Rails.root.join("tmp/worker.prompt.txt").to_s, log_path: Rails.root.join("tmp/worker.log").to_s,
      last_message_path: Rails.root.join("tmp/worker.last.txt").to_s, env_path: Rails.root.join("tmp/worker.env").to_s
    )
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, worker.scope, "Confirmed backend boot failure at config/application.rb:22.")

    without_spawning_workers { TickRunJob.new.send(:tick_run, run) }

    request = SpawnRequest.open_only.find_by!(run_id: run.run_id, requested_role: "planner")
    expect(request.context).to include("Recovery artifact diagnosis.md from worker")
    expect(request.context).to include("Confirmed backend boot failure at config/application.rb:22.")
  end

  it "does not dispatch recovery work while an open blocking question exists, even if tick state predates it" do
    workspace = Workspace.create!(name: "tick-blocked-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "tick-blocked-#{SecureRandom.hex(4)}", task: "Do not race an unanswered question",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1,
      last_plan_summary: "Worker was assigned.", pending_spawn_keys: [], following_steps: []
    )
    UserQuestion.create!(
      run_id: run.run_id, asked_by: "chaperone", scope: "workflow-plan.md",
      text: "The chaperone review could not complete.", priority: "blocking", status: "open"
    )

    without_spawning_workers do
      TickRunJob.new.send(:tick_run, run)
    end

    expect(SpawnRequest.open_only.where(run_id: run.run_id, requested_role: "planner")).to be_empty
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
