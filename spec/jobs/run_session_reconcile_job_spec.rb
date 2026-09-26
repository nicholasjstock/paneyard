require "rails_helper"

RSpec.describe RunSessionReconcileJob do
  # This job is the safety net behind run_done. Its whole job is to notice
  # sessions that ended without reporting, so their runs stop holding a slot.
  it "completes the run when a session turns out to have died" do
    run, session = create_run_and_session(prefix: "reconcile-dead")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(status: "failed", outcome: "failed", result: "process gone", ended_at: Time.current)
    end

    expect { described_class.perform_now }.to have_enqueued_job(RunDispatchJob)

    expect(run.reload.status).to eq("failed")
    expect(session.reload.outcome).to eq("failed")
  end

  it "leaves a still-live session running and completes nothing" do
    run, _session = create_run_and_session(prefix: "reconcile-alive")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!) do |s|
      s.update!(agent_status: "working", last_seen_at: Time.current)
    end

    described_class.perform_now

    expect(run.reload.status).to eq("running")
  end

  # herdr being unreachable says nothing about any one session. Failing every
  # run at once because the socket blipped would be far worse than waiting.
  it "stops the sweep instead of failing every run when herdr itself is unreachable" do
    first, = create_run_and_session(prefix: "reconcile-herdr-a")
    second, = create_run_and_session(prefix: "reconcile-herdr-b")
    allow(Orchestrator::RunSessionRunner).to receive(:refresh!)
      .and_raise(Orchestrator::Herdr::Error, "herdr is not running")

    expect { described_class.perform_now }.not_to raise_error

    expect(first.reload.status).to eq("running")
    expect(second.reload.status).to eq("running")
  end
end
