require "rails_helper"

RSpec.describe Orchestrator::RunPrompt do
  let(:run) do
    create_run(
      prefix: "run-prompt", task: "Add a unique index on users.email.",
      worktree_name: "run-prompt-a1b2", branch_name: "paneyard/run-prompt-a1b2",
      base_sha: "0123456789abcdef0123456789abcdef01234567"
    )
  end

  subject(:prompt) { described_class.compose(run:, session_driver: "claude") }

  it "states the run's identity, where it is working, and what it branched from" do
    expect(prompt).to include(run.run_id)
    expect(prompt).to include(run.target_root)
    expect(prompt).to include("paneyard/run-prompt-a1b2")
    expect(prompt).to include("0123456789ab")
    expect(prompt).to include(run.task)
  end

  # The operator tries a session's changes before anything is kept, so the
  # session must not commit on its own -- and must know where to merge when asked.
  it "tells the session to leave changes uncommitted and commit, push or merge each only when asked" do
    expect(prompt).to include("Leave your changes uncommitted")
    expect(prompt).to include("do only the one you are asked for")
    expect(prompt).to include('"Commit" means a local commit on this branch, nothing more')
    expect(prompt).to include("Push only when told to push")
    expect(prompt).to include("Merge only when told to merge, from the main checkout `#{run.workspace.source_root}`")
    expect(prompt).to include("needs no push first")
  end

  # A ready-made push command read as one step of a commit/push/merge recipe,
  # so sessions asked only to commit pushed their branch too.
  it "hands over no git push command" do
    expect(prompt).not_to match(/git push/)
    expect(prompt).not_to include("origin #{run.branch_name}")
  end

  # Everything downstream depends on report_idle arriving: Rails cannot tell
  # an idle session from a working one otherwise.
  it "spells out when to report and that questions belong in a blocked report" do
    expect(prompt).to include("report_idle")
    expect(prompt).to include("`done`,\n`blocked` or `failed`")
    expect(prompt).to include("question goes in a `blocked`\nsummary")
    expect(prompt).to include("does not end the run")
  end

  it "is short -- detail belongs in the repo's own files and the tool descriptions" do
    expect(prompt.bytesize - run.task.bytesize).to be < 1_500
  end

  it "gives the ToolSearch hint only to claude, the one driver that defers MCP tools" do
    expect(prompt).to include("ToolSearch")
    expect(described_class.compose(run:, session_driver: "codex")).not_to include("ToolSearch")
    expect(described_class.compose(run:, session_driver: "opencode")).not_to include("ToolSearch")
  end

  it "does not fence off any paths or mention the planner era" do
    expect(prompt).not_to include("off limits")
    expect(prompt).not_to match(/planner|pull request/i)
  end

  # Uploads are stored under the main checkout at queue time, before the
  # worktree exists, so the prompt must point there rather than at a tool.
  it "points the session at the absolute directory holding files attached at launch" do
    run.update!(launch_artifacts: [ { "name" => "failing-test.log", "source_path" => "failing-test.log" } ])
    dir = File.join(run.workspace.source_root, ".paneyard", "artifacts", run.run_id)

    expect(described_class.compose(run:, session_driver: "claude"))
      .to include("failing-test.log", dir)
  end

  it "omits the attachments line when nothing was attached" do
    expect(prompt).not_to include("Attached files")
  end
end
