require "rails_helper"

RSpec.describe McpTools::ReportIdleTool do
  before { allow(Orchestrator::Herdr).to receive(:notify) }

  # The whole point of the rewrite: reporting idle leaves the session running so
  # the operator can read the report and decide what happens next.
  it "records a checkpoint and leaves the session live" do
    run, session = create_run_and_session(prefix: "report-idle")

    response = described_class.call(
      runId: run.run_id, outcome: "done", summary: "Added the index and a regression test.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be_falsey
    expect(session.reload).to have_attributes(status: "done", outcome: "done", ended_at: nil)
    expect(session).to be_live
    expect(run.reload).to have_attributes(status: "awaiting_review")
    expect(run.checkpoints.map(&:summary)).to eq([ "Added the index and a regression test." ])
  end

  it "does not close the herdr pane or kill the process" do
    run, session = create_run_and_session(prefix: "report-idle-pane")
    allow(Orchestrator::Herdr).to receive(:workspace_close)

    described_class.call(runId: run.run_id, outcome: "done", summary: "Done.", server_context: { run_session_id: session.id })

    expect(Orchestrator::Herdr).not_to have_received(:workspace_close)
    expect(session.reload.herdr_pane_id).to be_present
  end

  # A run is a sequence of work intervals, each closed by its own report, so the
  # reports accumulate as history rather than overwriting one another.
  it "appends a checkpoint per report and keeps the newest as current state" do
    run, session = create_run_and_session(prefix: "report-idle-many")

    described_class.call(runId: run.run_id, outcome: "blocked", summary: "Needs a decision on the API shape.",
      server_context: { run_session_id: session.id })
    described_class.call(runId: run.run_id, outcome: "done", summary: "Took the documented shape and shipped it.",
      server_context: { run_session_id: session.id })

    expect(run.checkpoints.map(&:outcome)).to eq(%w[blocked done])
    expect(run.checkpoints.map(&:summary))
      .to eq([ "Needs a decision on the API shape.", "Took the documented shape and shipped it." ])
    expect(session.reload).to have_attributes(outcome: "done", result: "Took the documented shape and shipped it.")
    expect(session).to be_live
  end

  it "keeps the run non-terminal on every outcome, so the operator still decides" do
    %w[done blocked failed].each do |outcome|
      run, session = create_run_and_session(prefix: "report-idle-#{outcome}")

      described_class.call(runId: run.run_id, outcome:, summary: "Report.", server_context: { run_session_id: session.id })

      expect(run.reload).to have_attributes(status: "awaiting_review", stopped_at: nil)
      expect(run).to be_active
      expect(session.reload).to be_live
    end
  end

  it "refuses a capability belonging to a different run" do
    _run, session = create_run_and_session(prefix: "report-idle-a")
    other_run = create_run(prefix: "report-idle-b")

    response = described_class.call(
      runId: other_run.run_id, outcome: "done", summary: "Not mine.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(other_run.reload.checkpoints).to be_empty
  end

  it "refuses a capability whose session has already ended" do
    run, session = create_run_and_session(prefix: "report-idle-ended")
    session.update!(status: "done", outcome: "done", ended_at: Time.current)

    response = described_class.call(
      runId: run.run_id, outcome: "done", summary: "Twice.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(run.reload.checkpoints).to be_empty
  end

  it "only accepts the three real outcomes" do
    expect(described_class.input_schema.to_h.dig(:properties, :outcome, :enum))
      .to contain_exactly("done", "blocked", "failed")
  end
end
