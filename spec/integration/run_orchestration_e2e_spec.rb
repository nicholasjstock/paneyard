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

      # The planner can only request verification, not grant it directly --
      # Rails spawns an independent verifier worker (played here by the fake
      # agent harness) that must itself confirm the claim before the
      # criterion becomes verified and a second bounded decision can close
      # the run.
      # A worker's DB row is reconciled to "stopped" independently of, and
      # sometimes slightly after, its own worker_turn handoff -- Rails' own
      # dead-end recovery net (TickRunJob#request_recovery_planner_if_dead_end)
      # can legitimately ask the planner to re-confirm state once more before
      # the run settles. Rebuild the decision from current criterion state
      # rather than a fixed call count so any such extra, idempotent
      # "closing" decision doesn't make this flaky.
      decision_count = 0
      allow(Orchestrator::PlannerDecisionRunner).to receive(:call) do |decision:, **|
        decision_count += 1
        criterion_exists = run.acceptance_criteria.exists?(key: "requested-outcome")
        params =
          if criterion_exists
            {
              outcome: "decision", summary: "Independent verification confirmed the outcome; closing the run.",
              next_step: nil, following_steps: [], context_request: nil,
              acceptance_criteria: [], acceptance_updates: []
            }
          else
            {
              outcome: "decision", summary: "Requesting independent verification of the outcome.",
              next_step: nil, following_steps: [], context_request: nil,
              acceptance_criteria: [ { key: "requested-outcome", content: "The launched run is investigated and verified responsive." } ],
              acceptance_updates: [ { key: "requested-outcome", status: "ready_for_verification", evidence_ref: "verified-outcome.md" } ]
            }
          end
        Orchestrator::PlannerDecisionSubmission.call(decision:, params:)
        { usage: { input_tokens: 40, output_tokens: 10 }, model: "test-planner" }
      end

      wait_until(timeout: 15) do
        WorkerReconcileJob.perform_now
        perform_enqueued_jobs { TickRunJob.perform_now }
        run.reload.status == "completed"
      end

      expect(run.reload.acceptance_criteria.find_by!(key: "requested-outcome")).to have_attributes(
        status: "verified", evidence_ref: a_string_matching(/verifier-evidence/)
      )
      expect(run.stopped_at).to be_present
      expect(run.workers.where(role: "planner")).to be_empty
      expect(run.workers.where(role: "verifier").count).to eq(1)
      expect(decision_count).to be >= 2

      expect(run.bus_events.order(:created_at).pluck(:event_type)).to include(
        "spawn_request.created",
        "spawn_request.fulfilled",
        "run.status"
      )
    end
  end
end
