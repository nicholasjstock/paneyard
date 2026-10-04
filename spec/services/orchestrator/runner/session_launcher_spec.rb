require "rails_helper"

RSpec.describe Orchestrator::Runner::SessionLauncher do
  describe ".submit_prompt_if_unsent!" do
    let(:attempts) { described_class::PROMPT_SUBMIT_POLL_ATTEMPTS }
    let(:stable) { described_class::PROMPT_SUBMIT_STABLE_SAMPLES }
    let(:windows) { described_class::PROMPT_SUBMIT_RETRY_WINDOWS }
    let(:herdr) { Orchestrator::Runner::Herdr }

    before do
      allow(described_class).to receive(:sleep)
      allow(herdr).to receive(:agent_send_keys)
      allow(herdr).to receive(:notify)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    # One agent.get answer per sample, in order: a status string, or an
    # exception to raise. Once the list runs out, the agent stays in its last
    # status.
    def stub_statuses(*statuses)
      queue = statuses.dup
      allow(herdr).to receive(:agent_get).with("w1:p1") do
        status = queue.size > 1 ? queue.shift : queue.first
        raise status if status.is_a?(Exception)

        { "agent_status" => status }
      end
    end

    def submit!
      described_class.submit_prompt_if_unsent!("w1:p1", run_id: "run-1")
    end

    def idle(count) = Array.new(count, "idle")
    def working(count) = Array.new(count, "working")

    it "sends no Enter when the agent is working throughout" do
      stub_statuses(*working(attempts))

      expect(submit!).to be(true)
      expect(herdr).not_to have_received(:agent_send_keys)
      expect(Rails.logger).to have_received(:info).with(/run run-1 pane w1:p1: prompt picked up .*after 0 Enter\(s\) .*working x#{attempts}/)
    end

    it "samples the whole window even once the agent is seen working" do
      stub_statuses(*working(attempts))

      submit!

      expect(herdr).to have_received(:agent_get).exactly(attempts).times
    end

    it "sends one Enter, and stops, when the prompt is picked up after it" do
      stub_statuses(*idle(attempts), *working(windows.first))

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).with("w1:p1", [ "Enter" ]).once
      expect(herdr).to have_received(:agent_get).exactly(attempts + windows.first).times
      expect(Rails.logger).to have_received(:info)
        .with(/prompt picked up .*after 1 Enter\(s\) \(agent_status: idle x#{attempts}, ENTER, working x#{windows.first}\)/)
      expect(herdr).not_to have_received(:notify)
    end

    # run-20260929-194456-3ec1: the first Enter, at +10 s, was accepted by
    # herdr and ignored by claude; a later one submitted the prompt.
    it "sends another Enter when the first is ignored, and stops once the second works" do
      stub_statuses(*idle(attempts), *idle(windows[0]), *working(windows[1]))

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).with("w1:p1", [ "Enter" ]).twice
      expect(Rails.logger).to have_received(:warn).with(/prompt not seen picked up .*sending Enter 1\/#{windows.size}/)
      expect(Rails.logger).to have_received(:warn)
        .with(/prompt not seen picked up .*agent_status: idle x#{attempts}, ENTER, idle x#{windows[0]}\); sending Enter 2\/#{windows.size}/)
      expect(Rails.logger).to have_received(:info).with(/prompt picked up .*after 2 Enter\(s\)/)
    end

    it "gives up after a bounded number of Enters, warns, and lets the launch go on" do
      stub_statuses("idle")

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).exactly(windows.size).times
      expect(herdr).to have_received(:agent_get).exactly(attempts + windows.sum).times
      expect(Rails.logger).to have_received(:warn)
        .with(/run run-1 pane w1:p1: prompt still not seen picked up .*after agent.prompt and #{windows.size} Enters \(agent_status: idle x#{attempts}, ENTER, idle x#{windows[0]}, ENTER, .*\); leaving the session running/)
      expect(herdr).to have_received(:notify).with(hash_including(title: /run-1: prompt may be unsent/))
    end

    it "keeps the whole retry schedule to about a minute" do
      stub_statuses("idle")
      slept = []
      allow(described_class).to receive(:sleep) { |seconds| slept << seconds }

      submit!

      expect(slept.sum).to be_between(60, 80)
    end

    it "keeps retrying through an Enter that herdr rejects" do
      stub_statuses(*idle(attempts), *idle(windows[0]), *working(windows[1]))
      calls = 0
      allow(herdr).to receive(:agent_send_keys) do
        calls += 1
        raise Orchestrator::Runner::Herdr::Error, "boom" if calls == 1
      end

      expect { submit! }.not_to raise_error
      expect(calls).to eq(2)
      expect(Rails.logger).to have_received(:warn).with(/sending Enter failed: boom/)
    end

    # run-20260929-191533-d44e: the prompt stayed in claude's input box. The
    # old check took the first non-idle sample as "submitted" and returned.
    it "sends an Enter when the agent is non-idle briefly and then idle again" do
      stub_statuses("idle", "working", "working", *idle(attempts - 3), *working(windows.first))

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).with("w1:p1", [ "Enter" ]).once
      expect(Rails.logger).to have_received(:warn)
        .with(/run run-1 pane w1:p1: prompt not seen picked up .*agent_status: idle, working x2, idle x#{attempts - 3}\); sending Enter 1/)
    end

    it "does not count a brief blip as the agent having worked, so it keeps retrying" do
      stub_statuses("idle", "working", "working", *idle(attempts - 3 + windows[0]), *working(windows[1]))

      submit!

      expect(herdr).to have_received(:agent_send_keys).twice
    end

    # A fast task (or the fake agent) finishing inside the first window.
    it "sends one Enter but no retries when the agent worked and then went idle again" do
      stub_statuses(*working(attempts - 1), "idle")

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).once
      expect(herdr).to have_received(:agent_get).exactly(attempts + windows.first).times
      expect(Rails.logger).to have_received(:info).with(/agent was seen working and is idle again .*no more Enters/)
      expect(herdr).not_to have_received(:notify)
    end

    it "sends no Enter once the agent settles into working, however it started" do
      stub_statuses(*idle(attempts - stable), *working(stable))

      expect(submit!).to be(true)
      expect(herdr).not_to have_received(:agent_send_keys)
    end

    it "does not count a herdr error as the agent working" do
      stub_statuses(*working(attempts - 1), Orchestrator::Runner::Herdr::Error.new("boom"), *working(windows.first))

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).once
      expect(Rails.logger).to have_received(:warn).with(/working x#{attempts - 1}, error\(Error\)\); sending Enter 1/)
    end

    describe "after agent.prompt" do
      def submit_after!(timed_out:)
        described_class.submit_prompt_if_unsent!("w1:p1", run_id: "run-1", prompt: { seconds: 30.1, timed_out: })
      end

      it "logs how long agent.prompt took with the verdict" do
        stub_statuses(*working(attempts))

        described_class.submit_prompt_if_unsent!("w1:p1", run_id: "run-1", prompt: { seconds: 0.4, timed_out: false })

        expect(Rails.logger).to have_received(:info).with(/prompt picked up .*after agent.prompt \(which took 0.4s\), after 0 Enter/)
      end

      it "goes ahead when the agent picks up a prompt whose agent.prompt timed out" do
        stub_statuses(*working(attempts))

        expect(submit_after!(timed_out: true)).to be(true)
        expect(Rails.logger).to have_received(:info).with(/prompt picked up .*\(which timed out after 30.1s\)/)
      end

      it "fails the launch, saying what it saw, when agent.prompt timed out and the agent never stirred" do
        stub_statuses("idle")

        expect { submit_after!(timed_out: true) }.to raise_error(
          Orchestrator::Runner::LaunchError,
          /agent.prompt gave no reply within 30.1s, and the agent in pane w1:p1 then was never seen busy in .*s of watching, through #{windows.size} Enters \(agent_status: idle x#{attempts}, ENTER, .*\): its task most likely never arrived/
        )
        expect(herdr).to have_received(:agent_send_keys).exactly(windows.size).times
        expect(herdr).not_to have_received(:notify)
      end

      it "leaves a session that showed any sign of the prompt running, as when agent.prompt answered" do
        stub_statuses("working", *idle(attempts - 1), "idle")

        expect(submit_after!(timed_out: true)).to be(false)
        expect(herdr).to have_received(:notify).with(hash_including(title: /prompt may be unsent/))
      end

      it "never fails the launch over an idle agent when agent.prompt answered" do
        stub_statuses("idle")

        expect(submit_after!(timed_out: false)).to be(false)
      end
    end

    it "rides out a herdr error earlier in the window" do
      stub_statuses(Orchestrator::Runner::Herdr::Error.new("boom"), *working(attempts - 1))

      expect(submit!).to be(true)
      expect(herdr).not_to have_received(:agent_send_keys)
    end
  end

  describe ".deliver_prompt" do
    let(:herdr) { Orchestrator::Runner::Herdr }

    before { allow(Rails.logger).to receive(:warn) }

    it "sends the prompt once and says how long it took" do
      expect(herdr).to receive(:agent_prompt).with("w1:p1", "the task").once

      expect(described_class.deliver_prompt("w1:p1", "the task", run_id: "run-1")).to match(seconds: a_value < 1, timed_out: false)
    end

    # herdr may have delivered it: sending it again would type the task twice.
    it "neither resends nor fails on a timeout, and says so" do
      expect(herdr).to receive(:agent_prompt).once.and_raise(herdr::TimedOut, "herdr agent.prompt timed out after 30s")

      expect(described_class.deliver_prompt("w1:p1", "the task", run_id: "run-1")).to include(timed_out: true)
      expect(Rails.logger).to have_received(:warn).with(/run run-1 pane w1:p1: herdr agent.prompt timed out after 30s \(8-byte prompt\); not resending it/)
    end

    it "fails at once when herdr is not running" do
      allow(herdr).to receive(:agent_prompt).and_raise(herdr::Unreachable, "herdr is not running (No such file or directory)")

      expect { described_class.deliver_prompt("w1:p1", "the task", run_id: "run-1") }.to raise_error(herdr::Unreachable, /not running/)
    end
  end
end
