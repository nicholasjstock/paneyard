require "rails_helper"

RSpec.describe "workspace runs", type: :system do
  let(:workspace) do
    Workspace.create!(name: "runs-ui-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("runs-ui"))
  end

  it "queues a task and lands on its detail page, with nothing started yet" do
    visit workspace_runs_path(workspace)
    click_link "Queue a task"
    fill_in "Task", with: "Add a unique index on users.email"
    click_button "Queue"

    expect(page).to have_text("Add a unique index on users.email")
    expect(page).to have_text("Queued")
    expect(page).to have_text("Waiting for a free slot")
    expect(page).to have_current_path(%r{/runs/run-})
  end

  it "shows how full the machine is on the run list" do
    create_run_and_session(run: create_run(workspace:, prefix: "runs-ui-live"))
    create_run(workspace:, prefix: "runs-ui-waiting", status: "queued")

    visit workspace_runs_path(workspace)

    expect(page).to have_text("1 run in flight of #{Orchestrator::RunConcurrency.limit}")
    expect(page).to have_text("1 run queued")
  end

  # The message box is the operator's steering wheel and the thing that
  # replaced the whole question protocol -- it must be there whenever there
  # is a live session to talk to, and absent when there is not.
  it "offers a message box for a live session" do
    run = create_run(workspace:, prefix: "runs-ui-session", branch_name: "workflow/runs-ui-a1b2",
      worktree_name: "runs-ui-a1b2")
    create_run_and_session(run:, agent_status: "working")

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("agent: working")
    expect(page).to have_field("Send a message to this session")
    expect(page).to have_button("Stop run")
  end

  # The report_idle checkpoints are the run's narrative; the run screen shows
  # them rather than a scrape of the terminal, which the operator can watch
  # live in their own herdr client.
  it "lists the session's checkpoints in order and does not read the pane" do
    run = create_run(workspace:, prefix: "runs-ui-checkpoints")
    _run, session = create_run_and_session(run:)
    run.checkpoints.create!(run_session: session, outcome: "blocked", summary: "Need the migration name.")
    run.checkpoints.create!(run_session: session, outcome: "done", summary: "Added the index and a test.")
    allow(Orchestrator::RunSessionRunner).to receive(:snapshot)

    visit workspace_run_path(workspace, run)

    expect(page).to have_text(/Need the migration name\..*Added the index and a test\./m)
    expect(page).to have_no_text("Live pane")
    expect(Orchestrator::RunSessionRunner).not_to have_received(:snapshot)
  end

  it "offers no message box once the session has ended" do
    run = create_run(workspace:, prefix: "runs-ui-finished", status: "completed")
    _run, session = create_run_and_session(run:)
    session.update!(status: "done", outcome: "done", result: "Added the index and a test.", ended_at: Time.current)

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("done")
    expect(page).to have_no_field("Send a message to this session")
    expect(page).to have_no_button("Stop run")
  end

  # The janitor only leaves a finished run's worktree on disk when its work
  # exists nowhere else, so one that is still there is flagged, not hidden.
  # A "kept" worktree has to be a real git worktree -- see Run#kept_worktree?
  # -- so this needs an actual source checkout and `git worktree add`, not a
  # bare directory.
  it "flags a worktree kept after its run ended, offers its removal, and says nothing about pull requests" do
    workspace = Workspace.create!(name: "runs-ui-#{SecureRandom.hex(4)}", root_path: create_source_checkout)
    worktree = File.join(workspace.root_path, "runs-ui-kept-a1b2")
    system("git", "-C", workspace.source_root, "worktree", "add", "-b", "workflow/runs-ui-kept-a1b2",
      worktree, "HEAD", out: File::NULL, err: File::NULL) || raise("could not add worktree")
    File.write(File.join(worktree, "scratch.txt"), "unpushed\n")
    system("git", "-C", worktree, "add", "scratch.txt")
    system("git", "-C", worktree, "commit", "-m", "unpushed work", out: File::NULL, err: File::NULL)

    run = create_run(
      workspace:, prefix: "runs-ui-kept", status: "completed", stopped_at: 1.hour.ago,
      worktree_name: "runs-ui-kept-a1b2", branch_name: "workflow/runs-ui-kept-a1b2", target_root: worktree
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("workflow/runs-ui-kept-a1b2")
    expect(page).to have_text("worktree kept")
    expect(page).to have_button("Remove worktree")
    expect(page).to have_no_text(/pull request/i)

    visit workspace_runs_path(workspace)

    expect(page).to have_text("1 worktree kept")
    within(find(".card", text: "runs-ui-kept-a1b2")) { expect(page).to have_text("worktree kept") }
  end

  it "does not flag a finished run whose worktree is already gone" do
    run = create_run(
      workspace:, prefix: "runs-ui-released", status: "completed", stopped_at: 1.hour.ago,
      worktree_name: "runs-ui-released-a1b2", branch_name: "workflow/runs-ui-released-a1b2",
      target_root: File.join(workspace.root_path, "runs-ui-released-a1b2")
    )

    visit workspace_run_path(workspace, run)
    expect(page).to have_no_text("worktree kept")
    expect(page).to have_no_button("Remove worktree")

    visit workspace_runs_path(workspace)
    expect(page).to have_no_text("worktree kept")
  end

  it "stops a live run from the detail page" do
    run = create_run(workspace:, prefix: "runs-ui-stop")
    create_run_and_session(run:)
    allow(Orchestrator::RunSessionRunner).to receive(:finish!)

    visit workspace_run_path(workspace, run)
    click_button "Stop run"

    expect(page).to have_text("Stopped #{run.run_id}")
    expect(run.reload.status).to eq("stopped")
  end
end
