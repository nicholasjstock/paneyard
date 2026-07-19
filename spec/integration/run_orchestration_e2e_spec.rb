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
    it "launches, runs one bounded #{launcher_variant} planner decision, and completes the run" do
      workspace = Workspace.create!(name: "planner-#{launcher_variant}", root_path: @workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{launcher_variant}",
        task: "Investigate why the launched run appears stuck in the UI.",
        target_root: workspace.root_path,
        launcher_variant: launcher_variant,
        status: "launching",
        launched_by: "operator"
      )
      Orchestrator::ProjectMemory.record!(
        run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
        content: "Not exercised by this spec.", evidence_ref: "n/a", recorded_by: "project_init"
      )

      LaunchRunJob.perform_now(run.id)

      expect(run.reload.status).to eq("running")
      expect(run.spawn_requests.open_only.count).to eq(1)

      File.write(File.join(@workspace_root, "verified-outcome.md"), "The launched run is responsive.")

      allow(Orchestrator::PlannerDecisionRunner).to receive(:call).and_return(
        summary: "Bounded planner completed the run.", next_step: nil, following_steps: [],
        acceptance_criteria: [ { key: "requested-outcome", content: "The launched run is investigated and verified responsive." } ],
        acceptance_updates: [ { key: "requested-outcome", status: "verified", evidence_ref: "verified-outcome.md" } ],
        usage: { input_tokens: 40, output_tokens: 10 }, model: "test-planner"
      )

      perform_enqueued_jobs do
        TickRunJob.perform_now
      end

      expect(run.reload.status).to eq("completed")
      expect(run.stopped_at).to be_present
      expect(run.workers.where(role: "planner")).to be_empty
      expect(run.planner_decisions.last).to have_attributes(
        status: "completed", model: "test-planner", input_tokens: 40, output_tokens: 10
      )

      expect(run.bus_events.order(:created_at).pluck(:event_type)).to include(
        "spawn_request.created",
        "spawn_request.fulfilled",
        "run.status"
      )
    end
  end
end
