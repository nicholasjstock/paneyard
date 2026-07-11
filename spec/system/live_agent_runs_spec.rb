require "rails_helper"

RSpec.describe "live agent workspace runs", type: :system, live_agent: true do
  LiveAgentSpecs.variants.each do |launcher_variant|
    it "shows visible progress on the run page for #{launcher_variant}", :js, live_agent: true do
      workspace_root = LiveAgentSpecs.workspace_root_for(launcher_variant)
      skip "Set LIVE_AGENT_WORKSPACE_ROOT or LIVE_AGENT_#{launcher_variant.upcase}_WORKSPACE_ROOT for #{launcher_variant}" if workspace_root.blank?
      skip "#{launcher_variant} is not installed" unless system("which #{launcher_variant} >/dev/null 2>&1")

      FileUtils.mkdir_p(File.join(workspace_root, "front", "demo-output", "agents-sdk"))
      workspace = Workspace.create!(
        name: "live-ui-#{launcher_variant}-#{SecureRandom.hex(4)}",
        root_path: workspace_root
      )

      visit workspace_runs_path(workspace)
      climate_control("WORKFLOW_RAILS_URL" => Capybara.current_session.server.base_url) do
        click_link "Launch task"
        fill_in "Task", with: "Use workflow tools only. Publish status, write a minimal workflow-plan artifact, and complete the run."
        select launcher_variant, from: "Launcher"
        click_button "Launch"

        run = wait_until(timeout: 10) { Run.order(:created_at).last }
        expect(page).to have_current_path(workspace_run_path(workspace, run))
        expect(page).to have_text(run.run_id)

        Thread.new do
          TickRunJob.perform_now

          wait_until(timeout: LiveAgentSpecs.timeout_seconds) do
            tick = OrchestratorTick.for_run(run.run_id).last
            tick&.phase == "completed"
          end

          wait_until(timeout: 30) do
            WorkerReconcileJob.perform_now
            TickRunJob.perform_now
            run.reload.status == "completed"
          end
        rescue StandardError => e
          Rails.logger.error("live_agent_runs_spec background loop failed: #{e.class}: #{e.message}")
          raise
        end

        expect(page).to have_text("spawn_request.created", wait: LiveAgentSpecs.timeout_seconds)
        expect(page).to have_text("planner", wait: LiveAgentSpecs.timeout_seconds)
        expect(page).to have_text("completed", wait: LiveAgentSpecs.timeout_seconds), failure_details(run)
        expect(page).to have_text("workflow-plan.md", wait: LiveAgentSpecs.timeout_seconds), failure_details(run)
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

  def failure_details(run)
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
    lines.join("\n")
  end
end
