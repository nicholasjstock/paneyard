require "rails_helper"

RSpec.describe McpTools::RecordRunContextEntryTool do
  it "does not let a worker create or overwrite planner-owned acceptance criteria" do
    root = Dir.mktmpdir("context-tool")
    workspace = Workspace.create!(name: "context-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "context-#{SecureRandom.hex(4)}", task: "Verify it",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    Orchestrator::RunContext.apply_planner_acceptance!(
      run:, criteria: [ { key: "outcome", content: "The outcome is verified." } ], updates: []
    )

    expect do
      described_class.call(
        runId: run.run_id, key: "outcome", kind: "fact", status: "confirmed",
        content: "Worker says done", createdBy: "worker", evidenceRef: "report.md", server_context: nil
      )
    end.to raise_error(ArgumentError, /only be changed by a planner/)
    expect do
      described_class.call(
        runId: run.run_id, key: "new-outcome", kind: "acceptance_criterion", status: "pending",
        content: "Worker criterion", createdBy: "worker", server_context: nil
      )
    end.to raise_error(ArgumentError, /only be changed by a planner/)
  end
end
