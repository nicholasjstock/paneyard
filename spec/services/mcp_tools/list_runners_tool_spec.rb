require "rails_helper"

RSpec.describe McpTools::ListRunnersTool do
  it "lists only the local runner on a single machine" do
    workspace = create_workspace(prefix: "list-runners-only")
    create_run_and_session(run: create_run(workspace:, prefix: "list-runners-busy"))

    listed = described_class.call(server_context: {}).structured_content

    expect(listed[:runners]).to eq([
      { name: "local", kind: "local", url: nil, maxConcurrentRuns: nil, inFlight: 1, workspaces: [ workspace.name ], reachable: true }
    ])
    expect(listed[:capacity]).to eq(limit: Orchestrator::RunConcurrency.limit, inFlight: 1)
  end

  it "lists every runner, local first, with its cap, in-flight runs, checkouts and whether it answers" do
    workspace = create_workspace(prefix: "list-runners-ws")
    closed = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    laptop = RegisteredRunner.create!(name: "a-laptop", kind: "remote", url: "http://127.0.0.1:#{closed}", max_concurrent_runs: 2)
    workspace.checkouts.create!(runner: laptop, repository_path: "/Users/me/code/app")
    create_run(workspace:, prefix: "list-runners-launching", status: "launching", runner: laptop)

    with_runner_endpoint(runner: Orchestrator::Runner::Local.new(runtime_root: Dir.mktmpdir("list-runners"))) do |url|
      RegisteredRunner.create!(name: "b-mac", kind: "remote", url:)

      runners = described_class.call(server_context: {}).structured_content[:runners]

      expect(runners.map { |runner| runner[:name] }).to eq(%w[local a-laptop b-mac])
      expect(runners[1]).to include(kind: "remote", url: laptop.url, maxConcurrentRuns: 2, inFlight: 1,
        workspaces: [ workspace.name ], reachable: false, unreachableReason: include("did not answer ping"))
      expect(runners[2]).to include(kind: "remote", url:, inFlight: 0, workspaces: [], reachable: true)
    end
  end
end
