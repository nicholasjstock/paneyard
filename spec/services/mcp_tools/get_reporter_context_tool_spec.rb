require "rails_helper"

RSpec.describe McpTools::GetReporterContextTool do
  it "surfaces a worker's clickPath as its own howToSeeIt evidence field, not buried in the worker's diagnostic dump" do
    root = Dir.mktmpdir("get-reporter-context-click-path")
    workspace = Workspace.create!(name: "get-reporter-context-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "get-reporter-context-#{SecureRandom.hex(4)}", task: "Add a dropdown",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-1", reason: "Add a dropdown",
      scope: "fix-summary.md", status: "stopped", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/worker-1.prompt").to_s,
      log_path: Rails.root.join("tmp/worker-1.log").to_s,
      last_message_path: Rails.root.join("tmp/worker-1.last").to_s,
      env_path: Rails.root.join("tmp/worker-1.env").to_s,
      click_path: "Open the workspace, click the current-runs dropdown, select the long-title entry."
    )
    reporter = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Report it",
      scope: "run-summary.md", status: "running", pid: 12_346, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/reporter-1.prompt").to_s,
      log_path: Rails.root.join("tmp/reporter-1.log").to_s,
      last_message_path: Rails.root.join("tmp/reporter-1.last").to_s,
      env_path: Rails.root.join("tmp/reporter-1.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })

    expect(response.structured_content[:outputArtifact]).to eq("run-summary.md")
    evidence = response.structured_content[:evidence]
    expect(evidence[:request]).to eq("Add a dropdown")
    expect(evidence[:audience]).to eq("the reviewer of the resulting pull request")
    expect(evidence[:howToSeeIt]).to eq("Open the workspace, click the current-runs dropdown, select the long-title entry.")
    worker_entry = evidence[:workers].find { |entry| entry[:workerId] == worker.worker_id }
    expect(worker_entry).not_to have_key(:clickPath)
  end

  it "surfaces the most recently completed planner decision's summary and proposed step as plan-approval evidence" do
    root = Dir.mktmpdir("get-reporter-context-pending-plan")
    workspace = Workspace.create!(name: "get-reporter-context-decision-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "get-reporter-context-decision-#{SecureRandom.hex(4)}", task: "Add a feature",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    PlannerDecision.create!(
      run:, spawn_request: request, status: "completed", completed_at: 1.minute.ago,
      decision: {
        summary: "Implement the fix.",
        next_step: { artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes" }
      }
    )
    reporter = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Explain the plan",
      scope: "plan-summary-abc.md", status: "running", pid: 12_347, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/reporter-2.prompt").to_s,
      log_path: Rails.root.join("tmp/reporter-2.log").to_s,
      last_message_path: Rails.root.join("tmp/reporter-2.last").to_s,
      env_path: Rails.root.join("tmp/reporter-2.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })

    expect(response.structured_content[:outputArtifact]).to eq("plan-summary-abc.md")
    evidence = response.structured_content[:evidence]
    expect(evidence[:request]).to eq("Add a feature")
    expect(evidence[:audience]).to eq("the operator, deciding whether to approve this before any code is written")
    expect(evidence[:planSummary]).to eq("Implement the fix.")
    expect(evidence[:proposedStep][:artifact]).to eq("fix.md")
    expect(evidence[:proposedStep][:writeScope]).to eq("scoped_changes")
  end

  it "refuses to hand the reporter plan-approval evidence when no completed planner decision exists" do
    root = Dir.mktmpdir("get-reporter-context-no-decision")
    workspace = Workspace.create!(name: "get-reporter-context-no-decision-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "get-reporter-context-no-decision-#{SecureRandom.hex(4)}", task: "Add a feature",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    reporter = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Explain the plan",
      scope: "plan-summary-abc.md", status: "running", pid: 1, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/reporter-nodecision.prompt").to_s, log_path: Rails.root.join("tmp/reporter-nodecision.log").to_s,
      last_message_path: Rails.root.join("tmp/reporter-nodecision.last").to_s, env_path: Rails.root.join("tmp/reporter-nodecision.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })

    expect(response.error?).to be(true)
    expect(response.structured_content[:message]).to include("completed planner decision")
  end

  it "exposes the operator's original ask under the same `request` key for both evidence shapes" do
    finalization_root = Dir.mktmpdir("get-reporter-context-symmetry-finalization")
    finalization_workspace = Workspace.create!(name: "get-reporter-context-symmetry-final-#{SecureRandom.hex(4)}", root_path: finalization_root)
    finalization_run = finalization_workspace.runs.create!(
      run_id: "get-reporter-context-symmetry-final-#{SecureRandom.hex(4)}", task: "Shared wording",
      target_root: finalization_root, launcher_variant: "claude", status: "running"
    )
    finalization_reporter = finalization_run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Report it",
      scope: "run-summary.md", status: "running", pid: 1, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/symmetry-final.prompt").to_s, log_path: Rails.root.join("tmp/symmetry-final.log").to_s,
      last_message_path: Rails.root.join("tmp/symmetry-final.last").to_s, env_path: Rails.root.join("tmp/symmetry-final.env").to_s
    )

    plan_root = Dir.mktmpdir("get-reporter-context-symmetry-plan")
    plan_workspace = Workspace.create!(name: "get-reporter-context-symmetry-plan-#{SecureRandom.hex(4)}", root_path: plan_root)
    plan_run = plan_workspace.runs.create!(
      run_id: "get-reporter-context-symmetry-plan-#{SecureRandom.hex(4)}", task: "Shared wording",
      target_root: plan_root, launcher_variant: "claude", status: "running"
    )
    plan_spawn_request = plan_run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    PlannerDecision.create!(
      run: plan_run, spawn_request: plan_spawn_request, status: "completed", completed_at: 1.minute.ago,
      decision: { summary: "Do the thing.", next_step: { artifact: "fix.md" } }
    )
    plan_reporter = plan_run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Explain the plan",
      scope: "plan-summary-xyz.md", status: "running", pid: 2, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/symmetry-plan.prompt").to_s, log_path: Rails.root.join("tmp/symmetry-plan.log").to_s,
      last_message_path: Rails.root.join("tmp/symmetry-plan.last").to_s, env_path: Rails.root.join("tmp/symmetry-plan.env").to_s
    )

    finalization_evidence = described_class.call(runId: finalization_run.run_id, server_context: { worker_id: finalization_reporter.worker_id }).structured_content[:evidence]
    plan_evidence = described_class.call(runId: plan_run.run_id, server_context: { worker_id: plan_reporter.worker_id }).structured_content[:evidence]

    expect(finalization_evidence[:request]).to eq("Shared wording")
    expect(plan_evidence[:request]).to eq("Shared wording")
  end
end
