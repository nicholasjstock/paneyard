require "test_helper"

class Orchestrator::TickStateTest < ActiveSupport::TestCase
  test "returns a compact recent history by default and details on request" do
    run_id = "tick-history-#{SecureRandom.hex(4)}"
    workspace = Workspace.create!(name: "tick-history-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    Run.create!(
      workspace: workspace, run_id: run_id, task: "Tick history test", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running"
    )

    6.times do |index|
      Orchestrator::TickState.write(
        run_id: run_id,
        phase: "waiting_on_workers",
        tick_count: index + 1,
        last_plan_summary: "x" * 800,
        pending_spawn_keys: [ "request-#{index}" ],
        following_steps: [ { owner: "worker", artifact: "report-#{index}.md", success_check: "check" } ],
        last_stall_finding: nil
      )
    end

    compact = Orchestrator::TickState.history(run_id)
    detailed = Orchestrator::TickState.history(run_id, limit: 1, include_details: true)

    assert_equal "compact", compact[:history_mode]
    assert_equal 6, compact[:total_ticks]
    assert_equal [ 2, 3, 4, 5, 6 ], compact[:entries].map { |entry| entry[:tick_count] }
    assert_equal 1, compact[:entries].last[:pending_spawn_count]
    assert compact[:entries].last[:last_plan_summary].end_with?("…")
    assert_equal "detailed", detailed[:history_mode]
    assert_equal [ "request-5" ], detailed[:entries].first[:pending_spawn_keys]
  end
end
