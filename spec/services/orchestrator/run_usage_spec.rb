require "rails_helper"

RSpec.describe Orchestrator::RunUsage do
  it "combines worker and planner telemetry for chat and run views" do
    workspace = Workspace.create!(name: "usage-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
    started_at = 2.hours.ago
    run = workspace.runs.create!(
      run_id: "usage-#{SecureRandom.hex(4)}", task: "Measure usage", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", started_at:
    )
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "usage-worker", reason: "Measure", scope: "usage.md",
      status: "stopped", pid: 123, prompt_path: "/tmp/prompt", log_path: "/tmp/log", last_message_path: "/tmp/last",
      exit_status_path: "/tmp/exit", env_path: "/tmp/env", command: "codex", args: [], started_at:,
      model: "gpt-5.6-luna", agent_turn_count: 3, input_tokens: 1_000, output_tokens: 200,
      cache_read_input_tokens: 400, total_cost_usd: 0.12
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "plan.md", text: "Plan", requested_role: "planner",
      priority: "blocking", status: "fulfilled", fulfilled_by: "test"
    )
    run.planner_decisions.create!(
      spawn_request: request, status: "completed", model: "claude-haiku", model_calls: 2,
      input_tokens: 500, output_tokens: 100, cache_read_input_tokens: 200, total_cost_usd: 0.03
    )

    usage = Orchestrator::RunUsage.build(run, now: started_at + 2.hours)

    assert_equal 5, usage[:agent_turn_count]
    assert_equal 1_500, usage[:input_tokens]
    assert_equal 300, usage[:output_tokens]
    assert_equal 600, usage[:cache_read_input_tokens]
    assert_in_delta 0.15, usage[:total_cost_usd]
    assert_equal 7_200, usage[:elapsed_seconds]
    assert_equal({ "gpt-5.6-luna" => 1, "claude-haiku" => 1 }, usage[:models])
  end
end
