require "rails_helper"

# Runner::Remote against a real Runner::Endpoint over real HTTP (in this
# process: RunnerEndpointServer), so the request, the JSON and the error
# mapping are the real ones; the runner behind the endpoint is a Local or a
# double.
RSpec.describe Orchestrator::Runner::Remote do
  let(:runtime_root) { Dir.mktmpdir("remote-runner") }
  let(:local) { Orchestrator::Runner::Local.new(runtime_root:) }

  def remote(url)
    described_class.new(name: "mac", url:)
  end

  it "answers Local's methods with Local's plain data, binary attachments included" do
    repository = create_source_checkout

    with_runner_endpoint(runner: local) do |url|
      runner = remote(url)
      binary = "\x00\xFFpng".b

      expect(runner.ping).to eq("hostname" => Socket.gethostname, "runtime_root" => runtime_root)
      expect(runner.check_repository(path: repository)).to include("repository_path" => File.realpath(repository),
        "default_base_branch" => "main", "problems" => [])
      expect(runner.branch_exists?(repository_path: repository, branch: "main")).to be(true)
      expect(runner.checkout_branch(repository_path: repository)).to eq("main")
      path = runner.store_attachment(run_id: "run-1", name: "shot.png", content: binary)
      expect(File.binread(path)).to eq(binary)
      expect(runner.attachments(run_id: "run-1")).to eq([ { "name" => "shot.png", "content" => binary } ])
      expect(runner.process_alive?(Process.pid)).to be(true)
    end
  end

  it "hands a session spec over with its symbol keys, and returns what the runner did" do
    runner = instance_double(Orchestrator::Runner::Local)
    spec = { run_id: "run-1", driver: "claude", layout: [ { "name" => nil, "panes" => [ { "name" => "agent" } ] } ] }
    allow(runner).to receive(:open_session).with(spec).and_return("pane_id" => "w1:p1", "mcp_config_path" => "/x.json")
    allow(runner).to receive(:launch_agent).with(spec, pane_id: "w1:p1", mcp_config_path: "/x.json")
      .and_return("pid" => 42, "lost_prompts" => [])
    allow(runner).to receive(:agent_state).with("w1:p1").and_return(nil)

    with_runner_endpoint(runner:) do |url|
      expect(remote(url).open_session(spec)).to eq("pane_id" => "w1:p1", "mcp_config_path" => "/x.json")
      expect(remote(url).launch_agent(spec, pane_id: "w1:p1", mcp_config_path: "/x.json")).to eq("pid" => 42, "lost_prompts" => [])
      expect(remote(url).agent_state("w1:p1")).to be_nil
    end
  end

  it "raises what the runner raised: Error, Unreachable, and LaunchError with its lost prompts" do
    runner = instance_double(Orchestrator::Runner::Local)
    allow(runner).to receive(:agent_state).and_raise(Orchestrator::Runner::Unreachable, "herdr is not running")
    allow(runner).to receive(:send_prompt).and_raise(Orchestrator::Runner::Error, "no such pane")
    allow(runner).to receive(:launch_agent).and_raise(
      Orchestrator::Runner::SessionLauncher::PromptLost.new("lost it", lost_prompts: [ { "cli" => "claude" } ])
    )
    allow(runner).to receive(:snapshot).and_raise(KeyError, "key not found: :lines")

    with_runner_endpoint(runner:) do |url|
      expect { remote(url).agent_state("w1:p1") }.to raise_error(Orchestrator::Runner::Unreachable, "herdr is not running")
      expect { remote(url).send_prompt("w1:p1", "hi") }.to raise_error(Orchestrator::Runner::Error, "no such pane")
      expect { remote(url).launch_agent({ run_id: "r" }, pane_id: "w1:p1", mcp_config_path: "/x") }
        .to raise_error(Orchestrator::Runner::LaunchError) { |error| expect(error.lost_prompts).to eq([ { "cli" => "claude" } ]) }
      expect { remote(url).snapshot("w1:p1", lines: 5) }.to raise_error(Orchestrator::Runner::Error, /snapshot: key not found/)
    end
  end

  it "is Unreachable, never an answer, when nothing listens, a proxy answers instead, or the runner is too slow" do
    closed = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    expect { remote("http://127.0.0.1:#{closed}").agent_state("w1:p1") }.to raise_error(Orchestrator::Runner::Unreachable, /did not answer/)

    bad_gateway = ->(_env) { [ 502, { "content-type" => "text/html" }, [ "<h1>502 Bad Gateway</h1>" ] ] }
    with_runner_endpoint(runner: nil, app: bad_gateway) do |url|
      expect { remote(url).agent_state("w1:p1") }.to raise_error(Orchestrator::Runner::Unreachable, /HTTP 502, not a runner response/)
    end

    stub_const("#{described_class}::READ_TIMEOUT", 0.2)
    slow = ->(_env) { sleep 1; [ 200, {}, [ "{}" ] ] }
    with_runner_endpoint(runner: nil, app: slow) do |url|
      expect { remote(url).agent_state("w1:p1") }.to raise_error(Orchestrator::Runner::Unreachable)
    end
  end
end
