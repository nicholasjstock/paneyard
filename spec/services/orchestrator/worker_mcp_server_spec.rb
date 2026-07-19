require "rails_helper"

RSpec.describe Orchestrator::WorkerMcpServer do
  it "exposes worker-scoped tools without spawn or lifecycle authority" do
    tools = described_class.build(server_context: { worker_id: "worker-id" }).tools.keys

    expect(tools).to include("worker_turn", "write_workflow_artifact")
    expect(tools).not_to include(
      "append_spawn_request", "spawn_worker", "stop_worker", "publish_planner_jobs", "run_guarded_command"
    )
  end
end
