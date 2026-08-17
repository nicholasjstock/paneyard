require "rails_helper"

RSpec.describe Orchestrator::RunPrompt do
  let(:run) do
    create_run(
      prefix: "run-prompt", task: "Add a unique index on users.email.",
      worktree_name: "run-prompt-a1b2", branch_name: "workflow/run-prompt-a1b2"
    )
  end

  subject(:prompt) { described_class.compose(run:, session_driver: "claude") }

  it "states the run's identity and where it is working" do
    expect(prompt).to include(run.run_id)
    expect(prompt).to include(run.target_root)
    expect(prompt).to include("workflow/run-prompt-a1b2")
    expect(prompt).to include(run.task)
  end

  # Everything downstream depends on run_done arriving: publication, the run's
  # terminal status, and the concurrency slot.
  it "spells out the finish contract, including why not calling run_done is not an option" do
    expect(prompt).to include("run-summary.md")
    expect(prompt).to include("git push -u origin workflow/run-prompt-a1b2")
    expect(prompt).to include("run_done")
    expect(prompt).to include("concurrency slot")
    expect(prompt).to include("blocked")
    expect(prompt).to include("failed")
  end

  # The operator is watching the pane; asking there beats guessing, and is
  # what replaced the whole GitHub question round-trip.
  it "tells the session an operator is watching and can be asked" do
    expect(prompt).to include("watching this pane")
  end

  it "names the workspace's protected paths when it has any, and says nothing when it does not" do
    expect(prompt).not_to include("off limits")

    run.workspace.update!(protected_path_patterns: [ "db/schema.rb", "config/credentials.yml.enc" ])
    expect(described_class.compose(run:, session_driver: "claude"))
      .to include("off limits", "db/schema.rb", "config/credentials.yml.enc")
  end

  it "includes durable workspace memory so a session does not rediscover it" do
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "dev-environment", kind: "operational_rule",
      content: "Run bin/dev from the repository root.", evidence_ref: "bin/dev", recorded_by: "session"
    )

    expect(described_class.compose(run:, session_driver: "claude"))
      .to include("Durable project knowledge", "bin/dev")
  end

  it "points the session at any files the operator attached at launch" do
    run.update!(launch_artifacts: [ { "name" => "failing-test.log", "source_path" => "failing-test.log" } ])

    expect(described_class.compose(run:, session_driver: "claude"))
      .to include("read_workflow_artifact", "failing-test.log")
  end
end
