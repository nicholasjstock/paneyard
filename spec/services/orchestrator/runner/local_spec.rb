require "rails_helper"

RSpec.describe Orchestrator::Runner::Local do
  subject(:runner) { described_class.new(runtime_root: Dir.mktmpdir("runner-local")) }

  let(:herdr) { Orchestrator::Runner::Herdr }

  it "is the runner every workspace gets, for now" do
    expect(Orchestrator::Runner.for(Workspace.new)).to be_a(described_class)
    expect(Orchestrator::Runner.for(nil)).to be(Orchestrator::Runner.for(Workspace.new))
  end

  describe "#agent_state" do
    it "answers with herdr's agent status and the CLI's own session id" do
      allow(herdr).to receive(:agent_get).with("w1:p1")
        .and_return("agent_status" => "working", "agent_session" => { "value" => "cli-7" })

      expect(runner.agent_state("w1:p1")).to eq("agent_status" => "working", "cli_session_id" => "cli-7")
    end

    it "is nil when herdr says the pane is gone" do
      allow(herdr).to receive(:agent_get).and_raise(herdr::Error, "pane_not_found")

      expect(runner.agent_state("w1:p1")).to be_nil
    end

    it "raises Unreachable, not nil, when herdr never answered" do
      allow(herdr).to receive(:agent_get).and_raise(herdr::Unreachable, "herdr is not running")

      expect { runner.agent_state("w1:p1") }.to raise_error(Orchestrator::Runner::Unreachable, "herdr is not running")
    end
  end

  it "never lets herdr's own errors cross the boundary" do
    allow(herdr).to receive(:agent_prompt).and_raise(herdr::Error, "no such pane")
    expect { runner.send_prompt("w1:p1", "hi") }.to raise_error(Orchestrator::Runner::Error, "no such pane") { |error|
      expect(error).not_to be_a(herdr::Error)
    }

    allow(herdr).to receive(:agent_prompt).and_raise(herdr::Unreachable, "timed out")
    expect { runner.send_prompt("w1:p1", "hi") }.to raise_error(Orchestrator::Runner::Unreachable, "timed out")
  end

  it "degrades a snapshot it cannot read, and a workspace it cannot close, to nothing" do
    allow(herdr).to receive(:pane_read).and_raise(herdr::Unreachable, "timed out")
    allow(herdr).to receive(:workspace_close).and_raise(herdr::Error, "gone")

    expect(runner.snapshot("w1:p1", lines: 10)).to be_nil
    expect(runner.close_workspace("w1")).to be_nil
  end

  it "reports whether a process is alive, and treats one it may not signal as alive" do
    expect(runner.process_alive?(Process.pid)).to be(true)
    allow(Process).to receive(:kill).with(0, 999_999).and_raise(Errno::ESRCH)
    expect(runner.process_alive?(999_999)).to be(false)
    allow(Process).to receive(:kill).with(0, 1).and_raise(Errno::EPERM)
    expect(runner.process_alive?(1)).to be(true)
  end

  it "writes a session's runtime files under its own runtime root" do
    allow(herdr).to receive(:workspace_create)
      .and_return("root_pane" => { "pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1" })
    allow(Orchestrator::Runner::ProcessEnv).to receive(:sanitized_process_env).and_return({})

    opened = runner.open_session(
      run_id: "run/1", label: "run-1", driver: "claude", model: "opus", cwd: "/tmp", capability_token: "tok",
      prompt: "Do it", mcp_url: "http://127.0.0.1:3000/mcp", workspace_env: {}, env: {}, github_token: "ghs",
      ambient_github_auth: false, layout: [ { "name" => nil, "panes" => [ { "name" => "agent" } ] } ]
    )

    expect(opened).to include("pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1")
    expect(opened["prompt_path"]).to eq(File.join(runner.runtime_root, "run_1", "prompt.txt"))
    expect(File.read(opened["prompt_path"])).to eq("Do it")
    expect(JSON.parse(File.read(opened["mcp_config_path"])).dig("mcpServers", "paneyard", "url"))
      .to eq("http://127.0.0.1:3000/mcp/run")
    expect(herdr).to have_received(:workspace_create).with(hash_including(
      cwd: "/tmp", focus: false, env: hash_including("GH_TOKEN" => "ghs", "PANEYARD_RUN_TOKEN" => "tok")
    ))
  end
end
