require "rails_helper"

RSpec.describe Orchestrator::Runner::SessionLauncher do
  describe ".submit_prompt_if_unsent!" do
    let(:attempts) { described_class::PROMPT_SUBMIT_POLL_ATTEMPTS }
    let(:stable) { described_class::PROMPT_SUBMIT_STABLE_SAMPLES }

    before do
      stub_const("Orchestrator::Runner::SessionLauncher::PROMPT_SUBMIT_POLL_INTERVAL_SECONDS", 0)
      allow(Orchestrator::Runner::Herdr).to receive(:agent_send_keys)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    # One agent.get answer per sample, in order: a status string, or an
    # exception to raise.
    def stub_statuses(*statuses)
      expect(statuses.size).to eq(attempts)
      queue = statuses.dup
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w1:p1") do
        status = queue.shift
        raise status if status.is_a?(Exception)

        { "agent_status" => status }
      end
    end

    def submit!
      described_class.submit_prompt_if_unsent!("w1:p1", run_id: "run-1")
    end

    it "sends an Enter when the agent stays idle throughout" do
      stub_statuses(*Array.new(attempts, "idle"))

      expect(submit!).to be(false)
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).with("w1:p1", [ "Enter" ]).once
    end

    it "sends no Enter when the agent is working throughout" do
      stub_statuses(*Array.new(attempts, "working"))

      expect(submit!).to be(true)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_send_keys)
      expect(Rails.logger).to have_received(:info).with(/run run-1 pane w1:p1: prompt picked up .*working x#{attempts}/)
    end

    it "samples the whole window even once the agent is seen working" do
      stub_statuses(*Array.new(attempts, "working"))

      submit!

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_get).exactly(attempts).times
    end

    # run-20260929-191533-d44e: the prompt stayed in claude's input box. The
    # old check took the first non-idle sample as "submitted" and returned.
    it "sends an Enter when the agent is non-idle briefly and then idle again" do
      stub_statuses("idle", "working", "working", *Array.new(attempts - 3, "idle"))

      expect(submit!).to be(false)
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).with("w1:p1", [ "Enter" ]).once
      expect(Rails.logger).to have_received(:warn)
        .with(/run run-1 pane w1:p1: prompt not seen picked up .*agent_status: idle, working x2, idle x#{attempts - 3}\); sending Enter/)
    end

    it "sends an Enter when the agent drops back to idle on any of the last samples" do
      stub_statuses(*Array.new(attempts - 1, "working"), "idle")

      expect(submit!).to be(false)
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).once
    end

    it "sends no Enter once the agent settles into working, however it started" do
      stub_statuses(*Array.new(attempts - stable, "idle"), *Array.new(stable, "working"))

      expect(submit!).to be(true)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_send_keys)
    end

    it "does not count a herdr error as the agent working" do
      stub_statuses(*Array.new(attempts - 1, "working"), Orchestrator::Runner::Herdr::Error.new("boom"))

      expect(submit!).to be(false)
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).once
      expect(Rails.logger).to have_received(:warn).with(/working x#{attempts - 1}, error\(Error\)/)
    end

    it "rides out a herdr error earlier in the window" do
      stub_statuses(Orchestrator::Runner::Herdr::Error.new("boom"), *Array.new(attempts - 1, "working"))

      expect(submit!).to be(true)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_send_keys)
    end
  end
end
