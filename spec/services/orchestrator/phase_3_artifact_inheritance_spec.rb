require "rails_helper"

RSpec.describe "Phase 3: Artifact Inheritance" do
  describe "Planner decision methods examine prior_worker.produced_artifacts" do
    it "populates inherited_artifacts in SpawnRequest based on planner logic" do
      workspace = Workspace.create!(name: "phase3-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
      run = workspace.runs.create!(
        run_id: "phase3-#{SecureRandom.hex(4)}", task: "Test artifact inheritance",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running"
      )
      
      # Create a prior worker that produced artifacts
      prior_worker = run.workers.create!(
        worker_id: "worker-prior-#{SecureRandom.hex(4)}", role: "worker", nickname: "prior-worker",
        reason: "Diagnosis", scope: "diagnosis.md", pid: 12345,
        prompt_path: "/tmp/prompt.txt", log_path: "/tmp/log.txt",
        last_message_path: "/tmp/last.txt", env_path: "/tmp/env",
        command: "claude", status: "stopped", stopped_at: Time.current,
        produced_artifacts: ["diagnosis.md", "evidence.json"]
      )

      # Create a planner request (simulating a worker_turn completing)
      planner_request = run.spawn_requests.create!(
        asked_by: "worker", scope: "workflow-plan.md", text: "Choose next step.",
        requested_role: "planner", priority: "blocking", status: "fulfilled",
        fulfilled_by: "planner_decision_job"
      )

      # Create planner decision with acceptance criteria
      AcceptanceCriterion.create!(
        run_id: run.run_id, key: "test-outcome", status: "verified",
        content: "Test outcome", evidence_ref: "Gemfile"
      )
      decision = PlannerDecision.create!(run:, spawn_request: planner_request, status: "running")

      # Submit a planner decision that creates a new spawn request
      params = {
        outcome: "decision",
        summary: "Run verification using prior diagnostics.",
        next_step: {
          owner: "worker", artifact: "verify.md", success_check: "Confirm behavior.",
          mode: "verification", write_scope: "source_protected", allowed_paths: [], evidence_refs: [],
          addresses_criteria: ["test-outcome"]
        },
        following_steps: [],
        context_request: nil,
        acceptance_criteria: [],
        acceptance_updates: []
      }

      Orchestrator::PlannerDecisionSubmission.call(decision:, params:)

      # Verify that the new spawn request has inherited_artifacts populated
      new_request = run.spawn_requests.open_only.find_by!(requested_role: "worker")
      
      expect(new_request.inherited_artifacts).to include("diagnosis.md", "evidence.json")
      expect(new_request.artifact_inheritance_chain).to include(prior_worker.worker_id)
    end

    it "handles diagnosis mode correctly" do
      workspace = Workspace.create!(name: "phase3-diag-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
      run = workspace.runs.create!(
        run_id: "phase3-diag-#{SecureRandom.hex(4)}", task: "Test diagnosis with inheritance",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running"
      )

      # Create prior worker with produced artifacts
      prior_worker = run.workers.create!(
        worker_id: "worker-#{SecureRandom.hex(4)}", role: "worker", nickname: "initial-worker",
        reason: "Initial task", scope: "initial.md", pid: 12345,
        prompt_path: "/tmp/prompt.txt", log_path: "/tmp/log.txt",
        last_message_path: "/tmp/last.txt", env_path: "/tmp/env",
        command: "claude", status: "stopped", stopped_at: Time.current,
        produced_artifacts: ["initial.md", "notes.txt"]
      )

      # Create planner request
      planner_request = run.spawn_requests.create!(
        asked_by: "worker", scope: "workflow-plan.md", text: "Choose next step.",
        requested_role: "planner", priority: "blocking", status: "fulfilled",
        fulfilled_by: "planner_decision_job"
      )

      AcceptanceCriterion.create!(
        run_id: run.run_id, key: "next-step", status: "in_progress",
        content: "Do diagnosis", evidence_ref: "code"
      )
      decision = PlannerDecision.create!(run:, spawn_request: planner_request, status: "running")

      params = {
        outcome: "decision",
        summary: "Further diagnosis based on initial findings.",
        next_step: {
          owner: "worker", artifact: "diagnosis.md", success_check: "Identify root cause.",
          mode: "diagnosis", write_scope: "source_protected", 
          allowed_paths: [], evidence_refs: [],
          addresses_criteria: ["next-step"]
        },
        following_steps: [],
        context_request: nil,
        acceptance_criteria: [],
        acceptance_updates: []
      }

      Orchestrator::PlannerDecisionSubmission.call(decision:, params:)

      new_request = run.spawn_requests.open_only.find_by!(requested_role: "worker")
      
      # Verify artifact inheritance chain is recorded for auditing
      expect(new_request.artifact_inheritance_chain).to be_present
      expect(new_request.artifact_inheritance_chain.first).to eq(prior_worker.worker_id)
      expect(new_request.inherited_artifacts).to include("initial.md", "notes.txt")
    end

    it "handles runs with no prior worker gracefully" do
      workspace = Workspace.create!(name: "phase3-no-prior-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
      run = workspace.runs.create!(
        run_id: "phase3-no-prior-#{SecureRandom.hex(4)}", task: "Initial task",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running"
      )

      # No prior worker - planner is the initial step
      planner_request = run.spawn_requests.create!(
        asked_by: "orchestrator", scope: "workflow-plan.md", text: "Initial planning.",
        requested_role: "planner", priority: "blocking", status: "fulfilled",
        fulfilled_by: "launch_run_job"
      )

      AcceptanceCriterion.create!(
        run_id: run.run_id, key: "initial-task", status: "in_progress",
        content: "Complete initial task", evidence_ref: "none"
      )
      decision = PlannerDecision.create!(run:, spawn_request: planner_request, status: "running")

      params = {
        outcome: "decision",
        summary: "Start with diagnosis.",
        next_step: {
          owner: "worker", artifact: "initial-diagnosis.md", success_check: "Identify the target.",
          mode: "diagnosis", write_scope: "source_protected", allowed_paths: [], evidence_refs: [],
          addresses_criteria: ["initial-task"]
        },
        following_steps: [],
        context_request: nil,
        acceptance_criteria: [],
        acceptance_updates: []
      }

      Orchestrator::PlannerDecisionSubmission.call(decision:, params:)

      new_request = run.spawn_requests.open_only.find_by!(requested_role: "worker")
      
      # No prior worker means no inherited artifacts
      expect(new_request.inherited_artifacts).to be_empty
      expect(new_request.artifact_inheritance_chain).to be_empty
    end
  end
end
