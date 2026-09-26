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

  # Everything downstream depends on report_idle arriving: the run's
  # terminal status, and the concurrency slot.
  it "spells out the finish contract, including why not calling report_idle is not an option" do
    expect(prompt).not_to include("run-summary.md")
    expect(prompt).to include("full report in\nMarkdown")
    expect(prompt).to include("git push -u origin workflow/run-prompt-a1b2")
    expect(prompt).to include("report_idle")
    expect(prompt).to include("concurrency slot")
    expect(prompt).to include("blocked")
    expect(prompt).to include("failed")
  end

  # The operator is watching the pane; asking there beats guessing, and is
  # what replaced the whole GitHub question round-trip.
  it "tells the session an operator is watching and can be asked" do
    expect(prompt).to include("watching this pane")
  end

  it "does not fence off any paths -- the session owns its whole worktree" do
    expect(prompt).not_to include("off limits")
  end

  it "points the session at any files the operator attached at launch" do
    run.update!(launch_artifacts: [ { "name" => "failing-test.log", "source_path" => "failing-test.log" } ])

    expect(described_class.compose(run:, session_driver: "claude"))
      .to include("read_workflow_artifact", "failing-test.log")
  end
end
