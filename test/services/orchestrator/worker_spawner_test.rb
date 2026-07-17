require "test_helper"

class Orchestrator::WorkerSpawnerTest < ActiveSupport::TestCase
  test "Claude workers request incremental stream output" do
    args = Orchestrator::WorkerSpawner.send(:claude_args, "Do the work.", role: "worker")

    assert_includes args, "stream-json"
    assert_includes args, "--include-partial-messages"
    assert_equal "haiku", args[args.index("--model") + 1]
    assert_equal "Do the work.", args.last
  end

  test "Claude planners use Sonnet while all execution roles use Haiku" do
    assert_equal "sonnet", Orchestrator::WorkerSpawner.send(:claude_model_for, "planner")
    assert_equal "haiku", Orchestrator::WorkerSpawner.send(:claude_model_for, "worker")
    assert_equal "haiku", Orchestrator::WorkerSpawner.send(:claude_model_for, "infrastructure")
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
