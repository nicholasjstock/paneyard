require "rails_helper"

RSpec.describe "live agent orchestration", :live_agent do
  LiveAgentSpecs.variants.each do |launcher_variant|
    it "drives a run through the real #{launcher_variant} CLI", live_agent: true do
      workspace_root = LiveAgentSpecs.workspace_root_for(launcher_variant)
      skip "Set LIVE_AGENT_WORKSPACE_ROOT or LIVE_AGENT_#{launcher_variant.upcase}_WORKSPACE_ROOT for #{launcher_variant}" if workspace_root.blank?
      skip "#{launcher_variant} is not installed" unless system("which #{launcher_variant} >/dev/null 2>&1")

      FileUtils.mkdir_p(File.join(workspace_root, "front", "demo-output", "agents-sdk"))

      with_test_rails_server do |rails_url, server_log_path|
        climate_control("WORKFLOW_RAILS_URL" => rails_url) do
          workspace = Workspace.create!(
            name: "live-#{launcher_variant}-#{SecureRandom.hex(4)}",
            root_path: workspace_root
          )
          run = workspace.runs.create!(
            run_id: "live-#{launcher_variant}-#{SecureRandom.hex(3)}",
            task: "Use the workflow tools only. Write the minimal workflow-plan artifact, publish status, and complete the run.",
            target_root: workspace.root_path,
            launcher_variant: launcher_variant,
            status: "launching",
            launched_by: "rspec-live"
          )

          LaunchRunJob.perform_now(run.id)
          TickRunJob.perform_now

          completed_tick = wait_until(timeout: LiveAgentSpecs.timeout_seconds) do
            tick = OrchestratorTick.for_run(run.run_id).last
            tick if tick&.phase == "completed"
          rescue StandardError
            failure_details(run, server_log_path)
            raise
          end

          wait_until(timeout: 30) do
            WorkerReconcileJob.perform_now
            TickRunJob.perform_now
            run.reload.status == "completed"
          end

          expect(completed_tick.phase).to eq("completed")
          expect(run.reload.status).to eq("completed")
          expect(run.stopped_at).to be_present

          artifact_path = Orchestrator::ArtifactStore.resolve_path(workspace.root_path, run.run_id, "workflow-plan.md")
          expect(File).to exist(artifact_path), failure_details(run, server_log_path)
        end
      end
    end
  end

  def climate_control(overrides)
    original = {}
    overrides.each do |key, value|
      original[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  def failure_details(run, server_log_path)
    worker = Worker.where(run_id: run.run_id).order(:created_at).last
    lines = []
    lines << "run_status=#{run.reload.status}"
    lines << "ticks=#{OrchestratorTick.for_run(run.run_id).map { |t| [ t.tick_count, t.phase ] }.inspect}"
    lines << "events=#{BusEvent.where(run_id: run.run_id).order(:created_at).pluck(:event_type).inspect}"
    if worker
      lines << "worker=#{worker.slice('role', 'nickname', 'status', 'pid', 'scope').inspect}"
      lines << "worker_log=#{File.read(worker.log_path)}" if File.exist?(worker.log_path)
      lines << "worker_last_message=#{File.read(worker.last_message_path)}" if File.exist?(worker.last_message_path)
    end
    lines << "server_log=#{File.read(server_log_path)}" if File.exist?(server_log_path)
    lines.join("\n")
  end
end
