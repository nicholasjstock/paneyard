require "rails_helper"

RSpec.describe StartRunSessionJob do
  it "starts the session (which provisions the worktree) and marks the run running" do
    run = create_run(prefix: "start-session", status: "launching")
    allow(Orchestrator::RunSessionRunner).to receive(:start!)

    described_class.perform_now(run.id)

    expect(Orchestrator::RunSessionRunner).to have_received(:start!).with(run, reopening: nil)
    expect(run.reload).to have_attributes(status: "running")
    expect(run.started_at).to be_present
  end

  it "hands a reopened run's previous session to the new one" do
    run = create_run(prefix: "start-session-reopened", status: "launching")
    previous = run.run_sessions.create!(driver: "claude", status: "done", outcome: "done", ended_at: 1.minute.ago, cli_session_id: "conv-1")
    allow(Orchestrator::RunSessionRunner).to receive(:start!)

    described_class.perform_now(run.id)

    expect(Orchestrator::RunSessionRunner).to have_received(:start!).with(run, reopening: previous)
  end

  it "keeps a report the session made while it was still launching" do
    run = create_run(prefix: "start-session-quick", status: "launching")
    allow(Orchestrator::RunSessionRunner).to receive(:start!) { run.update!(status: "awaiting_review") }

    described_class.perform_now(run.id)

    expect(run.reload).to have_attributes(status: "awaiting_review")
    expect(run.started_at).to be_present
  end

  # A run left stuck in "launching" would hold a concurrency slot forever,
  # wedging the dispatcher for every other queued run.
  it "fails the run and frees its slot when provisioning blows up" do
    run = create_run(prefix: "start-session-broken", status: "launching")
    allow(Orchestrator::RunSessionRunner).to receive(:start!)
      .and_raise(Orchestrator::Runner::Error, "Base branch `gone`: there is no local branch `gone`")

    expect { described_class.perform_now(run.id) }
      .to raise_error(Orchestrator::Runner::Error)
      .and have_enqueued_job(RunDispatchJob)

    expect(run.reload).to have_attributes(status: "failed")
    expect(run.launch_error).to include("no local branch")
  end

  it "does nothing for a run another dispatcher already moved on from" do
    run = create_run(prefix: "start-session-stale", status: "stopped")
    allow(Orchestrator::RunSessionRunner).to receive(:start!)

    described_class.perform_now(run.id)

    expect(Orchestrator::RunSessionRunner).not_to have_received(:start!)
  end
end
