require "rails_helper"

RSpec.describe Orchestrator::PlannerDecisionRunner do
  it "runs Claude once with tools disabled and returns a structured decision" do
    run, request = build_run_and_request
    response = {
      "structured_output" => {
        "outcome" => "decision",
        "summary" => "Verify the completed change.",
        "nextStep" => step("verify.md"),
        "followingSteps" => [],
        "contextRequest" => nil
      },
      "usage" => { "input_tokens" => 120, "output_tokens" => 40, "cache_read_input_tokens" => 0 },
      "total_cost_usd" => 0.01,
      "modelUsage" => { "claude-sonnet-5" => {} }
    }
    captured = nil
    runner = lambda do |env, *args, chdir:|
      captured = { env:, args:, chdir: }
      [ JSON.generate(response), "", fake_status(true) ]
    end

    result = Orchestrator::PlannerDecisionRunner.call(run:, request:, command_runner: runner)

    assert_equal "verify.md", result.dig(:next_step, :artifact)
    assert_equal "decision", result[:outcome]
    assert_nil result[:context_request]
    assert_equal 120, result.dig(:usage, :input_tokens)
    assert_includes captured[:args], "--tools"
    assert_equal "", captured[:args][captured[:args].index("--tools") + 1]
    assert_includes captured[:args], "--json-schema"
    assert_equal "haiku", captured[:args][captured[:args].index("--model") + 1]
    assert_equal "small", result[:model_tier]
    assert_equal run.target_root, captured[:chdir]
  end

  it "brief contains bounded current state instead of event or worker log history" do
    run, request = build_run_and_request
    request.update!(context: "x" * 8_000)

    brief = Orchestrator::PlannerBrief.build(run:, request:)

    assert_operator brief.length, :<, 15_000
    assert_includes brief, "following_steps"
    refute_includes brief, "bus_events"
    refute_includes brief, "worker_logs"
  end

  it "brief carries the latest chaperone conclusion and compact transitions" do
    run, request = build_run_and_request
    review, = ChaperoneReview.issue!(
      run:, lineage_key: "planner:test", step_attempt_ids: [], subject_type: "planner",
      subject_id: SecureRandom.uuid, summary: "Verification incorrectly requested repository paths."
    )
    review.update!(
      status: "completed", action: "promote", completed_at: Time.current,
      summary: "Use one strong retry to produce the remaining verification step."
    )
    Orchestrator::TickState.write(
      run_id: run.run_id, tick_count: 1, phase: "planning", pending_spawn_keys: [], following_steps: [],
      last_plan_summary: "Implementation completed; verification remains."
    )

    brief = Orchestrator::PlannerBrief.build(run:, request:)

    assert_includes brief, "Use one strong retry to produce the remaining verification step."
    assert_includes brief, "Implementation completed; verification remains."
  end

  private

  def build_run_and_request
    workspace = Workspace.create!(name: "planner-runner-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "planner-runner-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    [ run, request ]
  end

  def step(artifact)
    {
      "owner" => "worker", "artifact" => artifact, "successCheck" => "Confirm the expected behavior.",
      "mode" => "verification", "writeScope" => "artifact_only", "allowedPaths" => [], "evidenceRefs" => []
    }
  end

  def fake_status(success)
    Struct.new(:success?, :exitstatus).new(success, success ? 0 : 1)
  end
end
