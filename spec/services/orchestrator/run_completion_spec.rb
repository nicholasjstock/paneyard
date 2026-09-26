require "rails_helper"

RSpec.describe Orchestrator::RunCompletion do
  # Publication is the operator's decision, taken from the run screen after
  # they have read the pane. A run whose session is over is waiting for that
  # decision, so it is left non-terminal and nothing is pushed or opened.
  it "leaves a done run awaiting the operator rather than publishing it" do
    run = create_run(prefix: "completion-done", status: "running")

    expect { described_class.call(run:, outcome: "done", summary: "Shipped it.") }
      .not_to have_enqueued_job(PublishRunJob)

    expect(run.reload).to have_attributes(status: "awaiting_review", publication_status: nil)
    expect(run).to be_active
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

  it "records the outcome on the run's timeline" do
    run = create_run(prefix: "completion-event", status: "running")

    described_class.call(run:, outcome: "blocked", summary: "Which migration?")

    event = run.bus_events.find_by!(event_type: "run.finished")
    expect(event.payload).to include("outcome" => "blocked", "summary" => "Which migration?")
  end

  it "rejects an unknown outcome rather than silently leaving the run running" do
    run = create_run(prefix: "completion-unknown", status: "running")

    expect { described_class.call(run:, outcome: "sideways") }.to raise_error(ArgumentError, /unknown run outcome/)
    expect(run.reload.status).to eq("running")
  end
end
