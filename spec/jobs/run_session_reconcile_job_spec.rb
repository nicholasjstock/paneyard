require "rails_helper"

RSpec.describe RunSessionReconcileJob do
  # RunIdleReport notifies the operator's real herdr; a spec must never open
  # that socket.
  before { allow(Orchestrator::Runner::Herdr).to receive(:notify) }
  # A spec must not remove real worktrees either; the janitor's own specs cover
  # what release! keeps and removes.
  before { allow(Orchestrator::WorktreeJanitor).to receive(:release!).and_return(false) }
  # This job is the safety net for sessions that die unnoticed. Its whole job is
  # to spot sessions that stopped existing, so their runs stop holding a slot.
  it "completes the run when a session turns out to have died" do
    run, session = create_run_and_session(prefix: "reconcile-dead")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(status: "failed", outcome: "failed", result: "process gone", ended_at: Time.current)
    end

    expect { described_class.perform_now }.to have_enqueued_job(RunDispatchJob)

    expect(run.reload.status).to eq("failed")
    expect(session.reload.outcome).to eq("failed")
  end

  # Regression: refresh! now consults the session's last checkpoint before
  # guessing "failed" -- a session that already reported "done" and then died
  # (pane closed, process gone) completed the run, it did not fail it.
  it "completes the run as done when a session that already reported done then dies" do
    run, session = create_run_and_session(prefix: "reconcile-done-then-dead")
    Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Merged into main.")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(status: "done", outcome: "done", ended_at: Time.current)
    end

    described_class.perform_now

    expect(run.reload.status).to eq("completed")
    expect(session.reload.outcome).to eq("done")
  end

  it "leaves a still-live session running and completes nothing" do
    run, _session = create_run_and_session(prefix: "reconcile-alive")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(agent_status: "working", last_seen_at: Time.current)
    end

    described_class.perform_now

    expect(run.reload.status).to eq("running")
  end

  # An idle session is waiting on the operator, on purpose: pane open, process
  # up, slot held. Reaping it here would undo the entire point of reporting
  # idle rather than ending the run.
  it "leaves a session that has reported idle alone, however long it waits" do
    run, session = create_run_and_session(prefix: "reconcile-idle")
    Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Finished; over to you.")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(agent_status: "idle", last_seen_at: Time.current)
    end

    described_class.perform_now

    expect(session.reload).to be_live
    expect(session.ended_at).to be_nil
    expect(run.reload).to have_attributes(status: "awaiting_review", stopped_at: nil)
  end

  # herdr being unreachable says nothing about any one session. Failing every
  # run at once because the socket blipped would be far worse than waiting.
  it "stops the sweep instead of failing every run when herdr itself is unreachable" do
    first, = create_run_and_session(prefix: "reconcile-herdr-a")
    second, = create_run_and_session(prefix: "reconcile-herdr-b")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!)
      .and_raise(Orchestrator::Runner::Unreachable, "herdr is not running")

    expect { described_class.perform_now }.not_to raise_error

    expect(first.reload.status).to eq("running")
    expect(second.reload.status).to eq("running")
  end

  # Regression: this exercises RunSessionRunner.refresh! for real (the other
  # "herdr unreachable" example above stubs refresh! itself, which is exactly
  # why it kept passing while a real socket blip inside agent_get still
  # permanently failed an idle, already-"done" run). A session that already
  # reported done and is waiting on the operator must survive a transient
  # herdr outage untouched, not get overwritten with a false "failed".
  it "leaves an idle, already-done session untouched when herdr is briefly unreachable" do
    run, session = create_run_and_session(prefix: "reconcile-blip")
    Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Finished; over to you.")
    allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
      .and_raise(Orchestrator::Runner::Herdr::Unreachable, "herdr agent.get timed out after 5s")

    expect { described_class.perform_now }.not_to raise_error

    expect(session.reload).to have_attributes(status: "done", outcome: "done", ended_at: nil)
    expect(run.reload).to have_attributes(status: "awaiting_review", stopped_at: nil)
  end

  # Closing a run's herdr workspace by hand is the operator finishing with it
  # without an operator client polling, so it must release the worktree just as Close
  # session does, not leave it for the next ten-minute sweep.
  it "releases the worktree of a session whose pane is gone" do
    run, = create_run_and_session(prefix: "reconcile-release")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(status: "failed", outcome: "failed", result: "pane gone", ended_at: Time.current)
    end

    described_class.perform_now

    expect(Orchestrator::WorktreeJanitor).to have_received(:release!).with(run).once
  end

  it "does not release the worktree of a live or idle session" do
    live_run, = create_run_and_session(prefix: "reconcile-keep-live")
    idle_run, idle_session = create_run_and_session(prefix: "reconcile-keep-idle")
    Orchestrator::RunIdleReport.call(run: idle_run, session: idle_session, outcome: "done", summary: "Over to you.")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(agent_status: s.run == live_run ? "working" : "idle", last_seen_at: Time.current)
    end

    described_class.perform_now

    expect(Orchestrator::WorktreeJanitor).not_to have_received(:release!)
  end

  # The run is already completed and the sweep retries later, so one failed
  # removal must not abort the loop over the remaining sessions.
  it "keeps completing runs when releasing their worktrees fails" do
    first, = create_run_and_session(prefix: "reconcile-release-fail-a")
    second, = create_run_and_session(prefix: "reconcile-release-fail-b")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(status: "done", outcome: "done", ended_at: Time.current)
    end
    allow(Orchestrator::WorktreeJanitor).to receive(:release!)
      .and_raise(Orchestrator::Runner::Error, "git worktree remove failed")

    expect { described_class.perform_now }.not_to raise_error

    expect(first.reload.status).to eq("completed")
    expect(second.reload.status).to eq("completed")
    expect(Orchestrator::WorktreeJanitor).to have_received(:release!).twice
  end

  # A layout's extra panes (log tails, a dev server) are never looked at: only
  # the agent pane decides whether the session is alive, and when it is gone
  # the whole workspace goes with it -- before the worktree those extra panes
  # run in is released.
  context "with a layout's extra panes in the run's workspace" do
    before do
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)
      allow(Orchestrator::RunSessionRunner).to receive(:kill_process)
    end

    it "keys off the agent pane alone, however the other panes are doing" do
      _run, session = create_run_and_session(prefix: "reconcile-layout-live")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w1:p1").and_return("agent_status" => "idle")
      allow(Orchestrator::RunSessionRunner).to receive(:process_alive?).and_return(true)

      described_class.perform_now

      expect(session.reload).to be_live
      expect(Orchestrator::Runner::Herdr).not_to have_received(:workspace_close)
      expect(Orchestrator::WorktreeJanitor).not_to have_received(:release!)
    end

    it "closes the whole workspace before releasing the worktree when only the agent pane is gone" do
      run, session = create_run_and_session(prefix: "reconcile-layout-agent-gone")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w1:p1")
        .and_raise(Orchestrator::Runner::Herdr::Error, "pane_not_found")

      described_class.perform_now

      expect(session.reload).to be_ended
      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w1").ordered
      expect(Orchestrator::WorktreeJanitor).to have_received(:release!).with(run).ordered
    end
  end
end
