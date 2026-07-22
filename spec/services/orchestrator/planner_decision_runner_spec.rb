require "rails_helper"

RSpec.describe Orchestrator::PlannerDecisionRunner do
  it "runs Claude with exactly the submit_planner_decision tool wired in, and reports usage from the final envelope" do
    run, request, decision = build_run_request_and_decision
    envelope = {
      "usage" => { "input_tokens" => 120, "output_tokens" => 40, "cache_read_input_tokens" => 0 },
      "total_cost_usd" => 0.01,
      "modelUsage" => { "claude-sonnet-5" => {} }
    }
    captured = nil
    mcp_config = nil
    runner = lambda do |env, *args, chdir:|
      captured = { env:, args:, chdir: }
      # The MCP config is written to a Tempfile that Orchestrator::PlannerDecisionRunner
      # cleans up as soon as this block returns, so it must be read now, not after `.call` returns.
      mcp_config_path = args[args.index("--mcp-config") + 1]
      mcp_config = JSON.parse(File.read(mcp_config_path))
      [ JSON.generate(envelope), "", fake_status(true) ]
    end

    result = Orchestrator::PlannerDecisionRunner.call(run:, request:, decision:, command_runner: runner)

    assert_equal 120, result.dig(:usage, :input_tokens)
    assert_equal "claude-sonnet-5", result[:model]
    assert_includes captured[:args], "--mcp-config"
    assert_includes captured[:args], "--allowedTools"
    assert_equal "mcp__planner_decision__submit_planner_decision", captured[:args][captured[:args].index("--allowedTools") + 1]
    refute_includes captured[:args], "--json-schema"
    refute_includes captured[:args], "--tools"
    assert_includes mcp_config.dig("mcpServers", "planner_decision", "url"), "/mcp/planner-decision"
    assert_equal "haiku", captured[:args][captured[:args].index("--model") + 1]
    assert_equal run.target_root, captured[:chdir]
  end

  it "runs Codex with the submit_planner_decision MCP server wired in via -c overrides" do
    run, request, decision = build_run_request_and_decision(launcher_variant: "codex")
    captured = nil
    runner = lambda do |env, *args, chdir:|
      captured = { env:, args:, chdir: }
      [ "", "", fake_status(true) ]
    end

    result = Orchestrator::PlannerDecisionRunner.call(run:, request:, decision:, command_runner: runner)

    assert_equal({}, result[:usage])
    assert_equal "gpt-5.6-luna", result[:model]
    assert_includes captured[:args], "-c"
    overrides = captured[:args].each_index.select { |i| captured[:args][i] == "-c" }.map { |i| captured[:args][i + 1] }
    assert overrides.any? { |override| override.start_with?("mcp_servers.planner_decision.url=") }
    assert_includes overrides, 'mcp_servers.planner_decision.bearer_token_env_var="PLANNER_DECISION_TOKEN"'
    assert_includes overrides, 'mcp_servers.planner_decision.default_tools_approval_mode="approve"'
    assert captured[:env]["PLANNER_DECISION_TOKEN"].present?
  end

  it "uses Codex's small tier by default and its strong tier only for a promoted planner retry" do
    run, request, decision = build_run_request_and_decision(launcher_variant: "codex")
    captured = []
    runner = lambda do |_env, *args, chdir:|
      captured << args
      [ "", "", fake_status(true) ]
    end

    small = Orchestrator::PlannerDecisionRunner.call(run:, request:, decision:, command_runner: runner)
    strong = Orchestrator::PlannerDecisionRunner.call(run:, request:, decision:, model_tier: :strong, command_runner: runner)

    assert_equal "gpt-5.6-luna", captured[0][captured[0].index("--model") + 1]
    assert_equal "gpt-5.6-terra", captured[1][captured[1].index("--model") + 1]
    assert_equal "gpt-5.6-luna", small[:model]
    assert_equal "gpt-5.6-terra", strong[:model]
  end

  it "brief contains bounded current state instead of event or worker log history" do
    run, request, = build_run_request_and_decision
    request.update!(context: "x" * 8_000)

    brief = Orchestrator::PlannerBrief.build(run:, request:)

    assert_operator brief.length, :<, 15_000
    assert_includes brief, "following_steps"
    assert_includes brief, "submit_planner_decision"
    refute_includes brief, "bus_events"
    refute_includes brief, "worker_logs"
  end

  it "brief carries the latest chaperone conclusion and compact transitions" do
    run, request, = build_run_request_and_decision
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

  def build_run_request_and_decision(launcher_variant: "claude")
    workspace = Workspace.create!(name: "planner-runner-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "planner-runner-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant:, status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    [ run, request, decision ]
  end

  def fake_status(success)
    Struct.new(:success?, :exitstatus).new(success, success ? 0 : 1)
  end
end
