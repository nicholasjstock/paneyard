require "rails_helper"

RSpec.describe RunDispatchJob do
  around do |example|
    original = ENV["PANEYARD_MAX_CONCURRENT_RUNS"]
    example.run
    ENV["PANEYARD_MAX_CONCURRENT_RUNS"] = original
  end

  it "starts queued runs oldest first, up to the global limit" do
    ENV["PANEYARD_MAX_CONCURRENT_RUNS"] = "2"
    first = create_run(prefix: "dispatch-first", status: "queued", created_at: 3.minutes.ago)
    second = create_run(prefix: "dispatch-second", status: "queued", created_at: 2.minutes.ago)
    third = create_run(prefix: "dispatch-third", status: "queued", created_at: 1.minute.ago)

    expect { described_class.perform_now }.to have_enqueued_job(StartRunSessionJob).twice

    expect(first.reload.status).to eq("launching")
    expect(second.reload.status).to eq("launching")
    expect(third.reload.status).to eq("queued")
  end

  it "starts nothing when every slot is already occupied" do
    ENV["PANEYARD_MAX_CONCURRENT_RUNS"] = "1"
    create_run_and_session(prefix: "dispatch-busy")
    waiting = create_run(prefix: "dispatch-waiting", status: "queued")

    expect { described_class.perform_now }.not_to have_enqueued_job(StartRunSessionJob)
    expect(waiting.reload.status).to eq("queued")
  end

  # The claim is a conditional UPDATE precisely so two dispatchers racing for
  # the same run cannot both win it. Simulating the loser: the row is no
  # longer "queued" by the time this dispatcher's update lands.
  it "does not start a run another dispatcher already claimed" do
    ENV["PANEYARD_MAX_CONCURRENT_RUNS"] = "2"
    contested = create_run(prefix: "dispatch-contested", status: "queued", created_at: 2.minutes.ago)
    free = create_run(prefix: "dispatch-free", status: "queued", created_at: 1.minute.ago)

    allow(Run).to receive(:where).and_call_original
    allow(Run).to receive(:where).with(id: contested.id, status: "queued") do
      contested.update_columns(status: "launching")
      Run.none
    end

    described_class.perform_now

    expect(free.reload.status).to eq("launching")
  end

  it "does nothing at all when nothing is queued" do
    create_run(prefix: "dispatch-running", status: "running")

    expect { described_class.perform_now }.not_to have_enqueued_job(StartRunSessionJob)
  end
end
