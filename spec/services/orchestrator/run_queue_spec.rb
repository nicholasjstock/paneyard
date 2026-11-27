require "rails_helper"

RSpec.describe Orchestrator::RunQueue do
  let(:workspace) { create_workspace(prefix: "queue") }

  def queued(created_at:, **attributes)
    create_run(workspace:, prefix: "queue", status: "queued", base_branch: "main", created_at:, **attributes)
  end

  it "counts only older queued runs the dispatcher would start first" do
    running = create_run(workspace:, prefix: "queue", status: "running", base_branch: "main")
    failed = create_run(workspace:, prefix: "queue", status: "failed", base_branch: "main")
    eligible = queued(created_at: 5.minutes.ago)
    waiting = queued(created_at: 4.minutes.ago, dependency_run_ids: [ running.run_id ])
    blocked = queued(created_at: 3.minutes.ago, dependency_run_ids: [ failed.run_id ])
    run = queued(created_at: 1.minute.ago)
    queued(created_at: Time.current)

    expect(Orchestrator::RunDependencies.status(waiting)[:state]).to eq("waiting")
    expect(Orchestrator::RunDependencies.status(blocked)[:state]).to eq("blocked")
    expect(described_class.ahead_of(run)).to eq([ eligible ])
    expect(described_class.ahead_count(run)).to eq(1)
  end

  # The dispatcher's queue is global, like the concurrency cap.
  it "counts eligible runs in other workspaces too" do
    create_run(prefix: "queue-other", status: "queued", created_at: 2.minutes.ago)
    run = queued(created_at: 1.minute.ago)

    expect(described_class.ahead_count(run)).to eq(1)
  end

  it "is the order the dispatcher claims in, passing over what is not eligible" do
    failed = create_run(workspace:, prefix: "queue", status: "failed", base_branch: "main")
    blocked = queued(created_at: 2.minutes.ago, dependency_run_ids: [ failed.run_id ])
    run = queued(created_at: 1.minute.ago)

    RunDispatchJob.perform_now

    expect(run.reload.status).to eq("launching")
    expect(blocked.reload.status).to eq("queued")
  end
end
