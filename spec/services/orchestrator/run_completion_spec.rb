require "rails_helper"

RSpec.describe Orchestrator::RunCompletion do
  # There is nothing left for Rails to do with a done run once its session is
  # over -- the branch is pushed and GitHub is the operator's business -- so it
  # is terminal, which is also what lets WorktreeJanitor reclaim it later.
  it "completes a done run" do
    run = create_run(prefix: "completion-done", status: "awaiting_review")

    described_class.call(run:, outcome: "done", summary: "Shipped it.")

    expect(run.reload).to have_attributes(status: "completed")
    expect(run.stopped_at).to be_present
    expect(run).to be_terminal
  end

  it "stops a blocked run and fails a failed one" do
    blocked = create_run(prefix: "completion-blocked", status: "running")
    failed = create_run(prefix: "completion-failed", status: "running")

    described_class.call(run: blocked, outcome: "blocked", summary: "Needs a decision.")
    described_class.call(run: failed, outcome: "failed", summary: "Cannot be done.")

    expect(blocked.reload).to have_attributes(status: "stopped")
    expect(failed.reload).to have_attributes(status: "failed")
    expect(blocked.stopped_at).to be_present
  end

  # The slot this run held is free now; waiting out the dispatcher's own
  # interval would idle the machine for no reason.
  it "asks the dispatcher to look for queued work immediately" do
    run = create_run(prefix: "completion-slot", status: "running")

    expect { described_class.call(run:, outcome: "failed") }.to have_enqueued_job(RunDispatchJob)
  end

  it "rejects an unknown outcome rather than silently leaving the run running" do
    run = create_run(prefix: "completion-unknown", status: "running")

    expect { described_class.call(run:, outcome: "sideways") }.to raise_error(ArgumentError, /unknown run outcome/)
    expect(run.reload.status).to eq("running")
  end
end
