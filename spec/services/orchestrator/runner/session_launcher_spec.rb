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

    # The blip of the text arriving: it is probably in the input box.
    it "gives up after a bounded number of Enters, warns, and lets the launch go on once the agent stirred" do
      stub_statuses("working", "idle")

      expect(submit!).to be(false)
      expect(herdr).to have_received(:agent_send_keys).exactly(windows.size).times
      expect(herdr).to have_received(:agent_get).exactly(attempts + windows.sum).times
      expect(Rails.logger).to have_received(:warn)
        .with(/run run-1 pane w1:p1: prompt still not seen picked up .*after agent.prompt and #{windows.size} Enters \(agent_status: working, idle x#{attempts - 1}, ENTER, idle x#{windows[0]}, ENTER, .*\); leaving the session running/)
      expect(herdr).to have_received(:notify).with(hash_including(title: /run-1: prompt may be unsent/))
    end

    # run-20261012-174300-3933: agent.prompt answered in 0.3s, and claude
    # then sat idle through every sample and Enter without ever starting on
    # its task -- left running, it was a live, idle session that would never
    # report.
    it "says the task never arrived when the agent never stirred, through every Enter" do
      stub_statuses("idle")

      expect { submit! }.to raise_error(
        described_class::PromptNeverArrived,
        /after herdr agent.prompt, the agent in pane w1:p1 then was never seen busy in .*s of watching, through #{windows.size} Enters \(agent_status: idle x#{attempts}, ENTER, .*\): its task never arrived/
      )
      expect(herdr).to have_received(:agent_send_keys).exactly(windows.size).times
      expect(herdr).not_to have_received(:notify)
    end

    it "does not count herdr errors as the agent stirring" do
      stub_statuses(Orchestrator::Runner::Herdr::Error.new("boom"), "idle")

      expect { submit! }.to raise_error(described_class::PromptNeverArrived, /agent_status: error\(Error\), idle x/)
    end

    it "keeps the whole retry schedule to about a minute" do
      stub_statuses("working", "idle")
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

      it "says the task never arrived, and what it saw, when agent.prompt timed out and the agent never stirred" do
        stub_statuses("idle")

        expect { submit_after!(timed_out: true) }.to raise_error(
          described_class::PromptNeverArrived,
          /agent.prompt gave no reply within 30.1s, and the agent in pane w1:p1 then was never seen busy in .*s of watching, through #{windows.size} Enters \(agent_status: idle x#{attempts}, ENTER, .*\): its task never arrived/
        )
        expect(herdr).to have_received(:agent_send_keys).exactly(windows.size).times
        expect(herdr).not_to have_received(:notify)
      end

      it "leaves a session that showed any sign of the prompt running, as when agent.prompt answered" do
        stub_statuses("working", *idle(attempts - 1), "idle")

        expect(submit_after!(timed_out: true)).to be(false)
        expect(herdr).to have_received(:notify).with(hash_including(title: /prompt may be unsent/))
      end

      it "says the task never arrived when agent.prompt answered but the agent never stirred" do
        stub_statuses("idle")

        expect { submit_after!(timed_out: false) }.to raise_error(
          described_class::PromptNeverArrived, /agent.prompt answered in 30.1s, but the agent in pane w1:p1 then was never seen busy/
        )
      end
    end

    it "rides out a herdr error earlier in the window" do
      stub_statuses(Orchestrator::Runner::Herdr::Error.new("boom"), *working(attempts - 1))

      expect(submit!).to be(true)
      expect(herdr).not_to have_received(:agent_send_keys)
    end
  end

  describe ".launch" do
    let(:herdr) { Orchestrator::Runner::Herdr }
    let(:spec) { { run_id: "run-1", driver: "claude", cwd: "/tmp/wt", prompt: "the task" } }
    let(:shell) { { "shell_pid" => 100, "foreground_process_group_id" => 100, "foreground_processes" => [ { "pid" => 100 } ] } }
    let(:agent) { { "shell_pid" => 100, "foreground_process_group_id" => 555, "foreground_processes" => [ { "pid" => 555 } ] } }

    # `statuses` is the agent_status of each start of the CLI in turn; the
    # agent holds the pane's foreground from its start until it is signalled.
    def stub_starts(*statuses)
      starts = 0
      running = false
      allow(herdr).to receive(:agent_start) { starts += 1; running = true; nil }
      allow(herdr).to receive(:agent_get) do
        { "agent" => "claude", "interactive_ready" => true, "agent_status" => statuses.fetch(starts - 1) }
      end
      allow(herdr).to receive(:pane_process_info) { running ? agent : shell }
      allow(Process).to receive(:kill).with("SIGTERM", -555) { running = false; 1 }
    end

    def launch!
      described_class.launch(spec, pane_id: "w1:p1", mcp_config_path: "/tmp/mcp.json")
    end

    before do
      allow(described_class).to receive(:sleep)
      allow(described_class).to receive(:command).and_return([ "claude", [] ])
      allow(herdr).to receive(:pane_read).and_raise(herdr::Error, "no pane")
      allow(herdr).to receive(:ping).and_return("type" => "pong", "version" => "0.9.3")
      # Read for real in .unread_input_bytes's own examples.
      allow(described_class).to receive(:unread_input_bytes).with("w1:p1").and_return(1022)
      allow(herdr).to receive(:agent_prompt)
      allow(herdr).to receive(:agent_send_keys)
      allow(herdr).to receive(:notify)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    it "starts the agent once and sends its prompt once when it picks the prompt up" do
      stub_starts("working")

      expect(launch!).to eq("pid" => 555, "lost_prompts" => [])
      expect(herdr).to have_received(:agent_start).once
      expect(herdr).to have_received(:agent_prompt).with("w1:p1", "the task").once
      expect(Process).not_to have_received(:kill)
    end

    it "marks the folder trusted in its own CLI's config before starting it" do
      stub_starts("working")

      launch!
      expect(Orchestrator::Runner::ClaudeTrust).to have_received(:trust!).with("/tmp/wt")
      expect(Orchestrator::Runner::CodexTrust).not_to have_received(:trust!)
    end

    it "launches anyway when the folder could not be marked trusted" do
      stub_starts("working")
      allow(Orchestrator::Runner::ClaudeTrust).to receive(:trust!).and_raise(JSON::ParserError, "bad config")

      expect(launch!).to include("pid" => 555)
    end

    # A lobby (Orchestrator::LobbyOpen): the operator speaks to it first.
    it "only waits for the agent to be ready when there is no prompt, so there is nothing to lose" do
      stub_starts("idle")

      result = described_class.launch(spec.merge(prompt: nil), pane_id: "w1:p1", mcp_config_path: "/tmp/mcp.json")

      expect(result).to eq("pid" => 555, "lost_prompts" => [])
      expect(herdr).to have_received(:agent_start).once
      expect(herdr).not_to have_received(:agent_prompt)
      expect(herdr).not_to have_received(:agent_send_keys)
    end

    # run-20261012-174300-3933: the identical task queued again started at once.
    it "stops and starts the agent again, with the prompt sent afresh, when it never stirred" do
      stub_starts("idle", "working")

      expect(launch!).to include("pid" => 555)
      expect(Process).to have_received(:kill).with("SIGTERM", -555).once
      expect(herdr).to have_received(:agent_start).twice
      expect(herdr).to have_received(:agent_prompt).with("w1:p1", "the task").twice
      expect(Rails.logger).to have_received(:warn)
        .with(/run run-1 pane w1:p1: stopping claude and starting it again \(restart 1\/1\)/)
    end

    # The workaround's own record: whether it still fires, on which versions,
    # and whether herdr wrote the prompt the CLI never read.
    it "records what it knew about the lost prompt, read before the agent was stopped" do
      stub_starts("idle", "working")
      allow(herdr).to receive(:pane_read).with("w1:p1", source: "recent_unwrapped", lines: described_class::RESTART_SCREEN_LINES)
        .and_return("Some claude dialog\n\n")

      record = launch!.fetch("lost_prompts").sole

      expect(described_class).to have_received(:unread_input_bytes).once.ordered
      expect(Process).to have_received(:kill).with("SIGTERM", -555).ordered

      expect(record).to include(
        "herdr_version" => "0.9.3", "cli" => "claude", "cli_version" => "claude 9.9.9 (spec)",
        "unread_input_bytes" => 1022, "screen" => "Some claude dialog",
        "verdict" => a_string_matching(/never seen busy .*its task never arrived/)
      )
      expect(Time.iso8601(record.fetch("at"))).to be_within(5).of(Time.now)
      expect(Rails.logger).to have_received(:warn)
        .with(/\[lost-prompt\] run run-1 pane w1:p1: \{.*"herdr_version":"0.9.3".*"unread_input_bytes":1022.*\}\nIts screen was:\nSome claude dialog\z/m)
    end

    it "still records a lost prompt when nothing about it can be read" do
      stub_starts("idle", "working")
      allow(herdr).to receive(:ping).and_raise(herdr::Unreachable, "timed out")
      allow(described_class).to receive(:cli_version).and_return(nil)
      allow(described_class).to receive(:unread_input_bytes).and_return(nil)

      expect(launch!.fetch("lost_prompts").sole)
        .to include("herdr_version" => nil, "cli_version" => nil, "unread_input_bytes" => nil, "screen" => nil)
    end

    it "fails the launch, saying what it saw, when the restarted agent never stirs either" do
      stub_starts("idle", "idle")

      expect { launch! }.to raise_error(
        described_class::PromptLost,
        /the agent in pane w1:p1 then was never seen busy .*its task never arrived, on each of 2 starts of claude/
      ) { |error| expect(error.lost_prompts.map { it["unread_input_bytes"] }).to eq([ 1022, 1022 ]) }
      expect(herdr).to have_received(:agent_start).twice
      expect(Process).to have_received(:kill).once
      expect(herdr).not_to have_received(:notify)
    end

    it "restarts no agent that showed any sign of its prompt" do
      stub_starts("idle")
      # The blip of the text arriving, on the first sample after agent.prompt.
      blip = false
      allow(herdr).to receive(:agent_prompt) { blip = true }
      allow(herdr).to receive(:agent_get) do
        status = blip ? "working" : "idle"
        blip = false
        { "agent" => "claude", "interactive_ready" => true, "agent_status" => status }
      end

      expect(launch!).to eq("pid" => 555, "lost_prompts" => [])
      expect(herdr).to have_received(:agent_start).once
      expect(herdr).to have_received(:notify).with(hash_including(title: /prompt may be unsent/))
    end

    it "does not signal a process group the sandbox does not allow" do
      stub_starts("idle", "working")
      allow(Orchestrator::Sandbox).to receive(:allows_signal?).with(555).and_return(false)

      expect { launch! }.to raise_error(Orchestrator::Runner::LaunchError, /will not signal process group 555/)
      expect(Process).not_to have_received(:kill)
    end
  end

  describe ".open" do
    let(:runtime_root) { Dir.mktmpdir }
    let(:spec) do
      { run_id: "lobby-app", driver: "claude", cwd: "/repos/app", capability_token: nil, prompt: nil,
        mcp_url: "http://127.0.0.1:7263/mcp", mcp_endpoint: "admin", layout: [ { "panes" => [ { "name" => "agent" } ] } ],
        herdr_workspace_id: "w1", herdr_tab_id: "w1:t1", herdr_pane_id: "w1:p1" }
    end

    after { FileUtils.rm_rf(runtime_root) }

    it "writes a lobby's admin MCP config and no prompt file" do
      opened = described_class.open(spec, runtime_root:)

      expect(opened).to include("pane_id" => "w1:p1", "prompt_path" => nil)
      config = JSON.parse(File.read(opened.fetch("mcp_config_path")))
      expect(config.dig("mcpServers", "paneyard")).to eq("type" => "http", "url" => "http://127.0.0.1:7263/mcp/admin")
      expect(Dir.children(File.dirname(opened.fetch("mcp_config_path")))).to eq([ "mcp.json" ])
    end
  end

  # A real terminal, as the CLI has in its pane: the count is the kernel's.
  describe ".unread_input_bytes" do
    let(:herdr) { Orchestrator::Runner::Herdr }

    def with_terminal_process
      reader, writer, pid = PTY.spawn("sleep", "30")
      allow(herdr).to receive(:pane_process_info).with("w1:p1")
        .and_return("shell_pid" => 1, "foreground_process_group_id" => Process.getpgid(pid))
      yield writer
    ensure
      Process.kill("KILL", pid) if pid
      [ reader, writer ].compact.each(&:close)
    end

    it "counts the input waiting unread in the terminal of the pane's foreground process" do
      require "pty"
      with_terminal_process do |terminal|
        terminal.write("the task\r")
        sleep 0.2

        expect(described_class.unread_input_bytes("w1:p1")).to eq(9)
      end
    end

    it "says nothing for a process the sandbox would not let it signal" do
      require "pty"
      with_terminal_process do |terminal|
        terminal.write("the task\r")
        allow(Orchestrator::Sandbox).to receive(:allows_signal?).and_return(false)

        expect(described_class.unread_input_bytes("w1:p1")).to be_nil
      end
    end

    it "says nothing for a process with no terminal, or when herdr cannot say which it is" do
      allow(herdr).to receive(:pane_process_info).with("w1:p1").and_return("foreground_process_group_id" => Process.pid)
      expect(described_class.unread_input_bytes("w1:p1")).to be_nil

      allow(herdr).to receive(:pane_process_info).with("w1:p1").and_raise(herdr::Unreachable, "gone")
      expect(described_class.unread_input_bytes("w1:p1")).to be_nil
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
