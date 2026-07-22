require "rails_helper"

RSpec.describe "live Codex planner smoke", type: :system, live_agent: true do
  it "submits a real bounded planner decision through the planner MCP capability", :js, live_agent: true do
    workspace_root = LiveAgentSpecs.workspace_root_for("codex")
    skip "Set LIVE_AGENT_WORKSPACE_ROOT or LIVE_AGENT_CODEX_WORKSPACE_ROOT" if workspace_root.blank?
    skip "codex is not installed" unless system("which codex >/dev/null 2>&1")

    workspace = Workspace.create!(name: "live-codex-planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
    run = workspace.runs.create!(
      run_id: "live-codex-planner-#{SecureRandom.hex(4)}",
      task: "Create a bounded smoke-test plan without inspecting files or executing work.",
      target_root: workspace_root,
      launcher_variant: "codex",
      status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "system",
      requested_role: "planner",
      scope: "live-codex-planner-smoke",
      text: "Submit one valid initial planner decision. Define one acceptance criterion and one artifact-only diagnosis next step that addresses it.",
      priority: "blocking"
    )
    request.update!(
      status: "fulfilled",
      fulfilled_by: "live_planner_smoke",
      fulfilled_at: Time.current,
      fulfillment_note: "Reserved for the live planner smoke decision."
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")

    visit workspace_run_path(workspace, run)
    original_url = ENV["WORKFLOW_RAILS_URL"]
    ENV["WORKFLOW_RAILS_URL"] = Capybara.current_session.server.base_url
    allow(TickRunJob).to receive(:perform_later)

    PlannerDecisionJob.perform_now(decision.id)

    expect(decision.reload.status).to eq("completed")
    expect(decision.attempts.where(disposition: "accepted")).to exist
    expect(decision.decision.dig("next_step", "owner")).to eq("worker")
  ensure
    ENV["WORKFLOW_RAILS_URL"] = original_url
  end
end
