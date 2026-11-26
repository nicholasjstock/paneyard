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

  it "lists every runner, local first, with its cap, in-flight runs, checkouts and reachability" do
    workspace = create_workspace(prefix: "list-runners-ws")
    laptop = RegisteredRunner.create!(name: "a-laptop", kind: "remote", url: "http://laptop.tailnet:3100", max_concurrent_runs: 2)
    workspace.checkouts.create!(runner: laptop, repository_path: "/Users/me/code/app")
    create_run(workspace:, prefix: "list-runners-launching", status: "launching", runner: laptop)

    runners = described_class.call(server_context: {}).structured_content[:runners]

    expect(runners.map { |runner| runner[:name] }).to eq(%w[local a-laptop])
    expect(runners.last).to include(kind: "remote", url: "http://laptop.tailnet:3100", maxConcurrentRuns: 2, inFlight: 1,
      workspaces: [ workspace.name ], reachable: false, unreachableReason: include("not implemented"))
  end
end
