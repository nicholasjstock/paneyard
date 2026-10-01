require "rails_helper"

RSpec.describe Orchestrator::SessionClose do
  def stub_finish
    allow(Orchestrator::RunSessionRunner).to receive(:finish!) do |s, **|
      s.update!(status: "done", ended_at: Time.current)
    end
  end

  it "ends the session, settles the run from its last report, and frees the slot" do
    run, session = create_run_and_session(prefix: "session-close")
    session.update!(outcome: "blocked", result: "Needs a decision.")
    stub_finish
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).with(run).and_return(true)

    closed = nil
    expect { closed = described_class.call(run) }.to have_enqueued_job(RunDispatchJob)

    expect(closed).to eq(outcome: "blocked", worktree: "removed")
    expect(Orchestrator::RunSessionRunner).to have_received(:finish!).with(session, outcome: "blocked", result: "Needs a decision.")
    expect(run.reload.status).to eq("stopped")
  end

  it "counts a session that never reported as failed" do
    run, _session = create_run_and_session(prefix: "session-close-unreported")
    stub_finish
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).and_return(false)

    expect(described_class.call(run)).to eq(outcome: "failed", worktree: "kept")
    expect(run.reload.status).to eq("failed")
  end

  it "still closes the session when the worktree cannot be checked" do
    run, _session = create_run_and_session(prefix: "session-close-git")
    stub_finish
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).and_raise(Orchestrator::Runner::Error, "git exploded")

    expect(described_class.call(run)).to eq(outcome: "failed", worktree: "error", error: "git exploded")
  end

  it "refuses a run with no live session" do
    run = create_run(prefix: "session-close-none", status: "awaiting_review")

    expect { described_class.call(run) }.to raise_error(described_class::NoLiveSession)
  end
end
