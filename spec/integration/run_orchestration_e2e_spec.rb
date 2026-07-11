require "rails_helper"

RSpec.describe "run orchestration end to end" do
  around do |example|
    with_fake_agents do
      Dir.mktmpdir("workflow-workspace") do |dir|
        @workspace_root = dir
        FileUtils.mkdir_p(File.join(dir, "front", "demo-output", "agents-sdk"))
        example.run
      end
    end
  end

  %w[claude codex].each do |launcher_variant|
    it "launches, ticks, spawns a fake #{launcher_variant} planner, and completes the run" do
      workspace = Workspace.create!(name: "planner-#{launcher_variant}", root_path: @workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{launcher_variant}",
        task: "Investigate why the launched run appears stuck in the UI.",
        target_root: workspace.root_path,
        launcher_variant: launcher_variant,
        status: "launching",
        launched_by: "operator"
      )

      LaunchRunJob.perform_now(run.id)

      expect(run.reload.status).to eq("running")
      expect(run.spawn_requests.open_only.count).to eq(1)

      TickRunJob.perform_now

      worker = wait_until { Worker.where(run_id: run.run_id, role: "planner").order(:created_at).last }
      expect(worker).to have_attributes(role: "planner", status: "running")

      waiting_tick = wait_until(timeout: 10) do
        OrchestratorTick.for_run(run.run_id).last if OrchestratorTick.for_run(run.run_id).last&.phase == "waiting_on_workers"
      end
      expect(waiting_tick.phase).to eq("waiting_on_workers")

      artifact_path = Orchestrator::ArtifactStore.resolve_path(workspace.root_path, run.run_id, "workflow-plan.md")
      wait_until(timeout: 10) { File.exist?(artifact_path) }

      wait_until(timeout: 10) do
        WorkerReconcileJob.perform_now
        worker.reload.status == "stopped"
      end

      TickRunJob.perform_now
      wait_until(timeout: 10) { run.reload.status == "completed" }

      expect(run.reload.status).to eq("completed")
      expect(run.stopped_at).to be_present
      expect(worker.reload.status).to eq("stopped")

      expect(run.bus_events.order(:created_at).pluck(:event_type)).to include(
        "spawn_request.created",
        "spawn_request.fulfilled",
        "worker.spawned",
        "run.status",
        "worker.stopped"
      )

      expect(File).to exist(artifact_path)
      expect(File.read(artifact_path)).to include("Fake plan")
    end
  end
end
