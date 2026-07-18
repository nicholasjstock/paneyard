require "test_helper"

class Orchestrator::PlannerContextResolverTest < ActiveSupport::TestCase
  test "returns only a bounded window from a requested artifact" do
    run = build_run
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "report.md", "a" * 10_000)

    context = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: {
        source: "artifact", reference: "report.md", question: "What failed?", offset: 0, max_chars: 3_000
      }
    )

    assert_equal 3_000, context[:content].length
    assert_equal 3_000, context[:next_offset]
    assert_equal 3_000, context[:returned_bytes]
    assert context[:truncated]
    assert context[:available]
    assert_equal "What failed?", context[:question]

    next_context = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: {
        source: "artifact", reference: "report.md", question: "What failed?",
        offset: context[:next_offset], max_chars: 7_000
      }
    )
    assert_equal 7_000, next_context[:content].length
    assert_nil next_context[:next_offset]
  end


  test "marks missing and empty context as unavailable" do
    run = build_run

    missing = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: { source: "file", reference: "missing.md", question: "What is it?", offset: 0, max_chars: 1_000 }
    )
    empty_memory = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: { source: "run_context", reference: "unknown", question: "What is it?", offset: 0, max_chars: 1_000 }
    )

    refute missing[:available]
    refute empty_memory[:available]
  end

  test "rejects workspace file traversal" do
    run = build_run

    assert_raises(ArgumentError) do
      Orchestrator::PlannerContextResolver.resolve(
        run:, context_request: {
          source: "file", reference: "../secret", question: "Read it", offset: 0, max_chars: 1_000
        }
      )
    end
  end

  test "canonicalizes the exact current run artifact path to its safe filename" do
    run = build_run
    path = Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "workflow-plan.md", "measured baseline: 94 seconds")

    absolute = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: { source: "artifact", reference: path, question: "What is the baseline?", offset: 0, max_chars: 1_000 }
    )
    relative = Orchestrator::PlannerContextResolver.resolve(
      run:, context_request: {
        source: "artifact", reference: path.delete_prefix("#{run.target_root}/"),
        question: "What is the baseline?", offset: 0, max_chars: 1_000
      }
    )

    assert_equal "workflow-plan.md", absolute[:reference]
    assert_equal "workflow-plan.md", relative[:reference]
    assert_equal "measured baseline: 94 seconds", absolute[:content]
  end

  test "does not canonicalize an artifact path belonging to another run" do
    run = build_run

    assert_raises(ArgumentError) do
      Orchestrator::PlannerContextResolver.resolve(
        run:, context_request: {
          source: "artifact", reference: "front/demo-output/agents-sdk/another-run/workflow-plan.md",
          question: "Read it", offset: 0, max_chars: 1_000
        }
      )
    end
  end

  private

  def build_run
    root = Dir.mktmpdir("planner-context")
    workspace = Workspace.create!(name: "planner-context-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "planner-context-#{SecureRandom.hex(4)}", task: "Plan safely",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
