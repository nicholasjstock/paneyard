require "rails_helper"

RSpec.describe Orchestrator::RunCancel do
  let(:workspace) { create_workspace(prefix: "cancel") }

  def queued_run(**attributes)
    create_run(workspace:, prefix: "cancel", status: "queued", **attributes)
  end

  it "stops a queued run, records why, and takes no slot back from anyone" do
    run = queued_run

    described_class.call(run)

    expect(run.reload).to have_attributes(status: "stopped", stop_reason: described_class::REASON)
    expect(run.stopped_at).to be_present
    expect(run.checkpoints).to be_empty
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  it "is never then started by the dispatcher" do
    run = queued_run
    described_class.call(run)

    expect { RunDispatchJob.perform_now }.not_to have_enqueued_job(StartRunSessionJob)
    expect(run.reload.status).to eq("stopped")
  end

  %w[launching running awaiting_review].each do |status|
    it "refuses a run that is #{status}, pointing at close_session" do
      run = queued_run(status:)

      expect { described_class.call(run) }.to raise_error(described_class::NotCancellable, /close_session/)
      expect(run.reload.status).to eq(status)
    end
  end

  %w[stopped completed failed].each do |status|
    it "refuses a run that is already #{status}" do
      run = queued_run(status:, stopped_at: 1.minute.ago)

      expect { described_class.call(run) }.to raise_error(described_class::NotCancellable, /already #{status}/)
      expect(run.reload).to have_attributes(status:, stop_reason: nil)
    end
  end

  it "refuses a queued run that still has a live session" do
    run, _session = create_run_and_session(run: queued_run)

    expect { described_class.call(run) }.to raise_error(described_class::NotCancellable, /live session.*close_session/)
    expect(run.reload.status).to eq("queued")
  end

  # The same compare-and-set on "queued" the dispatcher claims with: when the
  # dispatcher gets there between the check and the update, the cancel loses
  # and the run is launched, not both.
  it "loses cleanly to the dispatcher claiming the run at the same moment" do
    run = queued_run
    claimed = raced = nil
    allow(Run).to receive(:where).and_call_original
    allow(Run).to receive(:where).with(id: run.id, status: "queued").and_wrap_original do |original, *args, **kwargs|
      # The first conditional update to land is the dispatcher's.
      unless raced
        raced = true
        claimed = RunDispatchJob.new.send(:claim_next_queued_run)
      end
      original.call(*args, **kwargs)
    end

    expect { described_class.call(run) }.to raise_error(described_class::NotCancellable, /launching.*close_session/)
    expect(claimed).to eq(run)
    expect(run.reload).to have_attributes(status: "launching", stop_reason: nil, stopped_at: nil)
  end

  it "leaves nothing for the dispatcher to claim once it has won" do
    run = queued_run
    described_class.call(run)

    expect(RunDispatchJob.new.send(:claim_next_queued_run)).to be_nil
    expect(run.reload.status).to eq("stopped")
  end

  it "blocks a run queued after it" do
    dependency = queued_run(base_branch: "main")
    dependent = queued_run(base_branch: "main", dependency_run_ids: [ dependency.run_id ])
    expect(Orchestrator::RunDependencies.status(dependent)[:state]).to eq("waiting")

    described_class.call(dependency)

    expect(Orchestrator::RunDependencies.status(dependent)).to include(state: "blocked",
      reason: include("#{dependency.run_id} stopped", "update_run_dependencies"))
    expect(Orchestrator::RunQueue.eligible?(dependent)).to be(false)
  end

  it "can be undone with reopen_session, which clears the reason" do
    run = queued_run
    described_class.call(run)
    allow(Orchestrator::Runner.local).to receive(:base_branch_problem).and_return(nil)

    expect(Orchestrator::SessionReopen.call(run)).to eq(worktree: "new")
    expect(run.reload).to have_attributes(status: "queued", stop_reason: nil)
  end
end
