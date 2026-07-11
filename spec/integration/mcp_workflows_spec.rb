require "rails_helper"

RSpec.describe "MCP workflow integrations" do
  it "publishes planner jobs and creates a worker spawn request" do
    run = create_run("mcp-plan")

    response = McpTools::PublishPlannerJobsTool.call(
      runId: run.run_id,
      task: "Fix the backend regression",
      verifierFinding: "backend request spec is failing",
      server_context: nil
    )

    expect(response.structured_content[:jobs]).not_to be_empty
    request = run.spawn_requests.order(:created_at).last
    expect(request).to have_attributes(asked_by: "planner", requested_role: "worker", scope: "fix-summary.md")
    expect(run.bus_events.order(:created_at).pluck(:event_type)).to include("spawn_request.created")
  end

  it "writes and reads orchestrator state and history through the tool layer" do
    run = create_run("mcp-state")

    write_response = McpTools::WriteOrchestratorStateTool.call(
      runId: run.run_id,
      phase: "planning",
      tickCount: 2,
      lastPlanSummary: "Plan the next handoff",
      pendingSpawnKeys: [ "key-1" ],
      followingSteps: [ { owner: "worker", artifact: "fix-summary.md", successCheck: "Ship a fix" } ],
      lastStallFinding: "stalled worker",
      lastUpdatedAt: Time.current.iso8601,
      server_context: nil
    )

    expect(write_response.structured_content[:state][:phase]).to eq("planning")

    read_response = McpTools::ReadOrchestratorStateTool.call(runId: run.run_id, server_context: nil)
    history_response = McpTools::ReadOrchestratorTickHistoryTool.call(runId: run.run_id, server_context: nil)

    expect(read_response.structured_content[:phase]).to eq("planning")
    expect(history_response.structured_content[:entries].last[:tickCount]).to eq(2)
  end

  it "publishes run status and surfaces the event in the recent-event tool" do
    run = create_run("mcp-status")

    status_response = McpTools::PublishRunStatusTool.call(
      runId: run.run_id,
      phase: "waiting_on_workers",
      owner: "orchestrator",
      summary: "Waiting for the planner result.",
      server_context: nil
    )
    events_response = McpTools::ListRecentEventsTool.call(server_context: nil, limit: 5)

    expect(status_response.structured_content[:phase]).to eq("waiting_on_workers")
    expect(events_response.structured_content[:events].map { |event| event[:type] }).to include("run.status")
  end

  it "round-trips workflow artifacts through the tool layer" do
    run = create_run("mcp-artifact")

    write_response = McpTools::WriteWorkflowArtifactTool.call(
      runId: run.run_id,
      artifactName: "workflow-plan.md",
      content: "# Plan\n\nShip the smallest fix.\n",
      server_context: nil
    )
    read_response = McpTools::ReadWorkflowArtifactTool.call(
      runId: run.run_id,
      artifactName: "workflow-plan.md",
      server_context: nil
    )

    expect(write_response.structured_content[:path]).to end_with("/workflow-plan.md")
    expect(read_response.structured_content[:content]).to include("Ship the smallest fix.")
  end

  it "creates and answers a user question through the tool layer" do
    run = create_run("mcp-question")

    create_response = McpTools::AppendUserQuestionTool.call(
      runId: run.run_id,
      askedBy: "planner",
      scope: "workflow-plan.md",
      text: "Should we roll back the feature?",
      priority: "blocking",
      tags: [ "decision" ],
      server_context: nil
    )
    question_id = create_response.structured_content[:questionId]

    answer_response = McpTools::AnswerUserQuestionTool.call(
      questionId: question_id,
      answeredBy: "operator",
      answerText: "No, keep the feature and patch it.",
      server_context: nil
    )

    expect(answer_response.structured_content[:status]).to eq("answered")
    expect(run.user_questions.find_by!(question_id: question_id).answer_text).to include("keep the feature")
    expect(run.bus_events.order(:created_at).pluck(:event_type)).to include("user_question.created", "user_question.answered")
  end

  it "turns a worker result into follow-up planner work" do
    run = create_run("mcp-worker-turn")
    McpTools::WriteOrchestratorStateTool.call(
      runId: run.run_id,
      phase: "planning",
      tickCount: 1,
      pendingSpawnKeys: [],
      followingSteps: [ { owner: "worker", artifact: "verifier-report.md", successCheck: "Verify the fix" } ],
      server_context: nil
    )

    response = McpTools::WorkerTurnTool.call(
      runId: run.run_id,
      role: "worker",
      nickname: "worker-1",
      scope: "fix-summary.md",
      result: "Fix applied and ready for follow-up planning.",
      task: run.task,
      server_context: nil
    )

    planner_request = run.spawn_requests.order(:created_at).last

    expect(response.structured_content[:plannerRequest][:requestId]).to eq(planner_request.request_id)
    expect(planner_request).to have_attributes(requested_role: "planner", scope: "workflow-plan.md")
  end

  it "turns a planner decision into completion state when nextStep is nil" do
    run = create_run("mcp-planner-turn")

    response = McpTools::PlannerTurnTool.call(
      runId: run.run_id,
      summary: "All work is complete.",
      nextStep: nil,
      followingSteps: [],
      server_context: nil
    )
    latest_state = Orchestrator::TickState.latest(run.run_id)

    expect(response.structured_content[:nextState][:phase]).to eq("completed")
    expect(latest_state[:phase]).to eq("completed")
  end

  it "keeps the run waiting_on_workers when planner_turn has no nextStep but a worker is still active" do
    run = create_run("mcp-planner-wait")
    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "worker",
      nickname: "worker-1",
      reason: "Still processing current step.",
      scope: "fix-summary.md",
      status: "running",
      pid: 123_456,
      prompt_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.prompt.txt"),
      log_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.log"),
      last_message_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.last-message.txt"),
      env_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.env.json"),
      command: "claude",
      args: []
    )

    response = McpTools::PlannerTurnTool.call(
      runId: run.run_id,
      summary: "Do not spawn a duplicate worker; let the current one continue.",
      nextStep: nil,
      followingSteps: [],
      server_context: nil
    )
    latest_state = Orchestrator::TickState.latest(run.run_id)

    expect(response.structured_content[:nextState][:phase]).to eq("waiting_on_workers")
    expect(latest_state[:phase]).to eq("waiting_on_workers")
  end

  it "requeues a worker step when the previous fulfilled worker died before writing its artifact" do
    run = create_run("mcp-worker-requeue")
    stale_worker_id = SecureRandom.uuid
    run.spawn_requests.create!(
      asked_by: "planner",
      scope: "phone-recording-report.md",
      text: "Record the phone demo again.",
      context: "Previous worker died before finishing.",
      requested_role: "worker",
      priority: "blocking",
      status: "fulfilled",
      fulfilled_by: "tick_run_job",
      fulfilled_at: 2.minutes.ago,
      fulfillment_note: "Spawned worker-1 (worker).",
      fulfilled_worker_id: stale_worker_id
    )
    run.workers.create!(
      worker_id: stale_worker_id,
      role: "worker",
      nickname: "worker-1",
      reason: "Old recording attempt.",
      scope: "phone-recording-report.md",
      status: "stopped",
      pid: 123_456,
      stopped_at: 2.minutes.ago,
      stop_reason: "Process exited before writing its artifact.",
      prompt_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.prompt.txt"),
      log_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.log"),
      last_message_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.last-message.txt"),
      env_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "worker-1.env.json"),
      command: "claude",
      args: []
    )

    response = McpTools::PlannerTurnTool.call(
      runId: run.run_id,
      summary: "Retry the same recording step because the first worker died before producing the artifact.",
      nextStep: {
        owner: "worker",
        artifact: "phone-recording-report.md",
        successCheck: "Write the recording report."
      },
      followingSteps: [],
      server_context: nil
    )

    expect(response.structured_content[:jobs].size).to eq(1)
    latest_request = run.spawn_requests.order(:created_at).last
    expect(latest_request.request_id).not_to eq(run.spawn_requests.order(:created_at).first.request_id)
    expect(latest_request).to have_attributes(status: "open", requested_role: "worker", scope: "phone-recording-report.md")
  end

  def create_run(suffix)
    unique_suffix = "#{suffix}-#{SecureRandom.hex(4)}"
    workspace = Workspace.create!(name: "planner-#{unique_suffix}", root_path: "/tmp/planner-#{unique_suffix}")
    FileUtils.mkdir_p(File.join(workspace.root_path, "front", "demo-output", "agents-sdk"))
    Run.create!(
      run_id: "demo-#{unique_suffix}",
      task: "Exercise MCP workflow #{suffix}",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )
  end
end
