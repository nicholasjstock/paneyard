require "rails_helper"

RSpec.describe Orchestrator::RunConcurrency do
  around do |example|
    original = ENV["WORKFLOW_MAX_CONCURRENT_RUNS"]
    example.run
    ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = original
  end

  describe ".limit" do
    it "defaults to 2 and ignores a blank or nonsensical override" do
      ENV.delete("WORKFLOW_MAX_CONCURRENT_RUNS")
      expect(described_class.limit).to eq(described_class::DEFAULT_LIMIT)

      ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = ""
      expect(described_class.limit).to eq(described_class::DEFAULT_LIMIT)

      ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = "not-a-number"
      expect(described_class.limit).to eq(described_class::DEFAULT_LIMIT)

      ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = "0"
      expect(described_class.limit).to eq(described_class::DEFAULT_LIMIT)
    end

    it "honours a positive override" do
      ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = "5"

      expect(described_class.limit).to eq(5)
    end
  end

  describe ".in_flight" do
    # A claimed run flips to "launching" before its session exists, and keeps
    # that status for a moment after. Summing the two states instead of taking
    # their union would count that run twice and leave the machine idle.
    it "counts a run claimed but not yet sessioned, and does not double-count one that is both" do
      claimed = create_run(prefix: "concurrency-claimed", status: "launching")
      expect(described_class.in_flight).to eq(1)

      create_run_and_session(run: claimed, prefix: "concurrency-claimed")
      expect(described_class.in_flight).to eq(1)

      create_run_and_session(prefix: "concurrency-other")
      expect(described_class.in_flight).to eq(2)
    end

    it "ignores runs whose session has ended, and queued runs" do
      _run, session = create_run_and_session(prefix: "concurrency-done")
      session.update!(status: "done", outcome: "done", ended_at: Time.current)
      create_run(prefix: "concurrency-queued", status: "queued")

      expect(described_class.in_flight).to eq(0)
    end

    # A blocked agent is sitting at a question in its own pane with the
    # process still up: that slot is genuinely occupied until someone answers.
    it "counts a blocked session as occupying its slot" do
      create_run_and_session(prefix: "concurrency-blocked", status: "blocked")

      expect(described_class.in_flight).to eq(1)
    end
  end

  describe ".available_slots" do
    it "never goes negative when more runs are in flight than the limit allows" do
      ENV["WORKFLOW_MAX_CONCURRENT_RUNS"] = "1"
      create_run_and_session(prefix: "concurrency-a")
      create_run_and_session(prefix: "concurrency-b")

      expect(described_class.available_slots).to eq(0)
    end
  end
end
