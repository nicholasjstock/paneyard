require "rails_helper"

RSpec.describe "live opencode chaperone smoke", type: :system, live_agent: true do
  it "completes a real capability-scoped chaperone MCP round trip", :js, live_agent: true do
    skip "opencode is not installed" unless system("which opencode >/dev/null 2>&1")

    workspace_root = LiveAgentSpecs.workspace_root_for("opencode")
    skip "Set LIVE_AGENT_OPENCODE_WORKSPACE_ROOT or LIVE_AGENT_WORKSPACE_ROOT" if workspace_root.blank?

    FileUtils.mkdir_p(File.join(workspace_root, "front", "demo-output", "agents-sdk"))
    workspace = Workspace.create!(name: "live-opencode-chaperone-#{SecureRandom.hex(4)}", root_path: workspace_root)
    run = workspace.runs.create!(
      run_id: "live-opencode-chaperone-#{SecureRandom.hex(4)}",
      task: "Exercise the chaperone capability only.",
      target_root: workspace_root,
      launcher_variant: "opencode",
      status: "running"
    )
    source = run.spawn_requests.create!(
      asked_by: "worker", requested_role: "worker", scope: "smoke-diagnosis", lineage_key: "smoke-diagnosis",
      text: "Document the bounded smoke failure.", priority: "blocking", status: "fulfilled"
    )
    attempt = StepAttempt.create!(
      run:, spawn_request: source, worker_id: SecureRandom.uuid, lineage_key: "smoke-diagnosis",
      mode: "diagnosis", outcome: "blocked", result: "Smoke-only blocked attempt."
    )
    review, = ChaperoneReview.issue!(
      run:, lineage_key: "smoke-diagnosis", step_attempt_ids: [ attempt.attempt_id ],
      summary: "Use only the chaperone MCP tools, then submit one bounded decision."
    )
    run.spawn_requests.create!(
      asked_by: "chaperone", requested_role: "chaperone", scope: review.lineage_key,
      lineage_key: review.lineage_key, text: review.summary, priority: "blocking", model_tier: "strong"
    )

    visit workspace_run_path(workspace, run)
    original_url = ENV["WORKFLOW_RAILS_URL"]
    ENV["WORKFLOW_RAILS_URL"] = Capybara.current_session.server.base_url

    Orchestrator::SpawnRequestedWorkers.call(run:)

    wait_until(timeout: LiveAgentSpecs.timeout_seconds) do
      WorkerReconcileJob.perform_now
      review.reload.status.in?(%w[completed failed])
    end

    expect(review.reload.status).to eq("completed")
    expect(review.tool_calls.map { |call| call.fetch("tool") }).to include(
      "get_chaperone_state", "submit_chaperone_decision"
    )
  ensure
    ENV["WORKFLOW_RAILS_URL"] = original_url
  end

  def wait_until(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield

      raise "Timed out waiting for the opencode chaperone smoke test" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 1
    end
  end
end
