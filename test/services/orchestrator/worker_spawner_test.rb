require "test_helper"

class Orchestrator::WorkerSpawnerTest < ActiveSupport::TestCase
  test "Claude workers request incremental stream output" do
    args = Orchestrator::WorkerSpawner.send(:claude_args, "Do the work.")

    assert_includes args, "stream-json"
    assert_includes args, "--include-partial-messages"
    assert_equal "Do the work.", args.last
  end

  test "infrastructure workers receive the generic worker contract and skill" do
    prompt = Orchestrator::WorkerSpawner.send(
      :build_prompt_with_persona, driver: "claude", role: "infrastructure", prompt: "Diagnose the outage."
    )

    assert_includes prompt, "call `worker_turn`"
    assert_includes prompt, "evidence-driven reliability investigation"
    assert_includes prompt, "Current task:\nDiagnose the outage."
  end
end
