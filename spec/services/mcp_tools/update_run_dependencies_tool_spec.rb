require "rails_helper"

RSpec.describe McpTools::UpdateRunDependenciesTool do
  let(:workspace) { create_workspace(prefix: "update-deps", repository_path: create_source_checkout) }

  def queued(prefix, after: [])
    create_run(workspace:, prefix:, status: "queued", base_branch: "main", dependency_run_ids: after)
  end

  def update(run, after)
    described_class.call(runId: run.run_id, workspace: workspace.name, after:, server_context: {})
  end

  it "releases a waiting run, and dispatches" do
    first = queued("deps-first")
    second = queued("deps-second", after: [ first.run_id ])

    response = nil
    expect { response = update(second, []) }.to have_enqueued_job(RunDispatchJob)

    expect(response.structured_content).to include(runId: second.run_id, after: [], dependencies: nil)
    expect(second.reload.dependency_run_ids).to eq([])
  end

  it "re-points a waiting run at another run" do
    first = queued("deps-first")
    other = queued("deps-other")
    second = queued("deps-second", after: [ first.run_id ])

    response = update(second, [ other.run_id ])

    expect(response.structured_content).to include(after: [ other.run_id ])
    expect(second.reload.dependency_run_ids).to eq([ other.run_id ])
  end

  it "refuses a cycle, directly or through another run, changing nothing" do
    first = queued("deps-first")
    second = queued("deps-second", after: [ first.run_id ])
    third = queued("deps-third", after: [ second.run_id ])

    direct = update(first, [ second.run_id ])
    indirect = update(first, [ third.run_id ])
    itself = update(first, [ first.run_id ])

    expect(direct.structured_content).to include(error: "dependency_invalid", message: include("would be a cycle"))
    expect(indirect.structured_content).to include(error: "dependency_invalid", message: include("#{third.run_id} already waits for #{first.run_id}"))
    expect(itself.structured_content[:message]).to include("cannot wait for itself")
    expect(first.reload.dependency_run_ids).to eq([])
  end

  it "refuses a run that has already launched" do
    first = queued("deps-first")
    running = create_run(workspace:, prefix: "deps-running", status: "running", base_branch: "main", branch_name: "paneyard/x")

    response = update(running, [ first.run_id ])

    expect(response.structured_content).to include(error: "not_waiting")
  end
end
