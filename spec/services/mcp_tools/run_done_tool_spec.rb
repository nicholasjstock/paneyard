require "rails_helper"

RSpec.describe McpTools::RunDoneTool do
  before { allow(Orchestrator::RunSessionRunner).to receive(:finish!) }

  it "ends the session and routes the run to publication on a done outcome" do
    run, session = create_run_and_session(prefix: "run-done")

    response = described_class.call(
      runId: run.run_id, outcome: "done", summary: "Added the index and a regression test.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be_falsey
    expect(Orchestrator::RunSessionRunner).to have_received(:finish!)
      .with(session, outcome: "done", result: "Added the index and a regression test.")
    expect(run.reload.publication_status).to eq("publishing")
  end

  it "stops the run without publishing when the session reports blocked" do
    run, session = create_run_and_session(prefix: "run-done-blocked")

    described_class.call(
      runId: run.run_id, outcome: "blocked", summary: "Needs a product decision.",
      server_context: { run_session_id: session.id }
    )

    expect(Orchestrator::RunSessionRunner).to have_received(:finish!)
      .with(session, outcome: "blocked", result: "Needs a product decision.")
    expect(run.reload).to have_attributes(status: "stopped", publication_status: nil)
  end

  it "refuses a capability belonging to a different run" do
    _run, session = create_run_and_session(prefix: "run-done-a")
    other_run = create_run(prefix: "run-done-b")

    response = described_class.call(
      runId: other_run.run_id, outcome: "done", summary: "Not mine.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(Orchestrator::RunSessionRunner).not_to have_received(:finish!)
    expect(other_run.reload.publication_status).to be_nil
  end

  it "refuses a capability whose session has already ended" do
    run, session = create_run_and_session(prefix: "run-done-ended")
    session.update!(status: "done", outcome: "done", ended_at: Time.current)

    response = described_class.call(
      runId: run.run_id, outcome: "done", summary: "Twice.",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(Orchestrator::RunSessionRunner).not_to have_received(:finish!)
  end

  it "only accepts the three real outcomes" do
    expect(described_class.input_schema.to_h.dig(:properties, :outcome, :enum))
      .to contain_exactly("done", "blocked", "failed")
  end
end
