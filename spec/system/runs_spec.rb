require "rails_helper"

RSpec.describe "workspace runs", type: :system do
  let(:workspace) do
    Workspace.create!(name: "runs-ui-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("runs-ui"))
  end

  before { allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return(nil) }

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
  it "offers a message box for a live session, with the pane snapshot beside it" do
    run = create_run(workspace:, prefix: "runs-ui-session", branch_name: "workflow/runs-ui-a1b2",
      worktree_name: "runs-ui-a1b2")
    create_run_and_session(run:, agent_status: "working")
    allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("$ bundle exec rspec\n3 examples, 0 failures")

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("agent: working")
    expect(page).to have_field("Send a message to this session")
    expect(page).to have_text("3 examples, 0 failures")
    expect(page).to have_button("Stop run")
  end

  it "offers no message box once the session has ended, and reports its outcome" do
    run = create_run(workspace:, prefix: "runs-ui-finished", status: "awaiting_review")
    _run, session = create_run_and_session(run:)
    session.update!(status: "done", outcome: "done", result: "Added the index and a test.", ended_at: Time.current)

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Added the index and a test.")
    expect(page).to have_no_field("Send a message to this session")
    expect(page).to have_no_button("Stop run")
  end

  it "surfaces the pull request and a worktree removal action once a run is over" do
    run = create_run(
      workspace:, prefix: "runs-ui-published", status: "completed", stopped_at: 1.hour.ago,
      worktree_name: "runs-ui-published-a1b2", branch_name: "workflow/runs-ui-published-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/7"
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_link("Pull request", href: run.pull_request_url)
    expect(page).to have_text("workflow/runs-ui-published-a1b2")
    expect(page).to have_button("Remove worktree")
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
