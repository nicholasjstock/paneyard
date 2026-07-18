require "rails_helper"

RSpec.describe "workspace runs", type: :system do
  it "launches a run and lands on the workspace-scoped detail page" do
    workspace = create_workspace

    visit workspace_runs_path(workspace)
    click_link "Launch task"
    fill_in "Task", with: "Investigate the slow recorded phone demo"

    perform_enqueued_jobs do
      click_button "Launch"
    end

    run = Run.order(:created_at).last

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.run_id)
    expect(page).to have_text("workspace: #{workspace.name}")
    expect(page).to have_text("What’s happening")
    expect(page).to have_text("Run Timeline")
  end

  it "opens the detail page from the workspace run list" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "detail-open", task: "Inspect the orchestrator detail page")

    visit workspace_runs_path(workspace)
    click_link run.run_id

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.task)
    expect(page).to have_text("What’s happening")
    expect(page).to have_text("Run Timeline")
  end

  it "updates the workspace run list live when a run is created", :js do
    workspace = create_workspace

    visit workspace_runs_path(workspace)
    expect(page).to have_text("No runs launched yet.")

    creator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        create_run(workspace: workspace, suffix: "list-live", task: "Appear on the workspace run list")
      end
    end

    expect(page).to have_text("Appear on the workspace run list")
    expect(page).to have_text("demo-list-live")

    creator.join
  end

  it "shows stale launching runs as launch queued" do
    workspace = create_workspace
    run = create_run(
      workspace: workspace,
      suffix: "stale-launch",
      task: "A launch job is stuck in the queue",
      status: "launching",
      started_at: nil
    )
    run.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)

    visit workspace_runs_path(workspace)

    expect(page).to have_text(run.run_id)
    expect(page).to have_text("launch queued")
    expect(page).to have_text("Launch job has not started.")
  end

  it "renders workers, spawn requests, and tick history on the run details page" do
    workspace = create_workspace
    FileUtils.mkdir_p(File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers"))
    run = create_run(workspace:, suffix: "detail-sections", task: "Render every detail section")
    run.update!(phase: "planning", phase_owner: "planner", phase_summary: "Choosing the next step.", phase_updated_at: Time.current)
    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "planner",
      nickname: "planner-main",
      reason: "Test the details page.",
      scope: "workflow-plan.md",
      status: "running",
      pid: 123_456,
      prompt_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-main.prompt.txt"),
      log_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-main.log"),
      last_message_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-main.last-message.txt"),
      env_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-main.env.json"),
      command: "claude",
      args: []
    )
    run.spawn_requests.create!(
      request_id: SecureRandom.uuid,
      asked_by: "planner",
      requested_role: "worker",
      scope: "fix-summary.md",
      text: "Investigate the failing path and report back.",
      status: "open",
      priority: "advisory"
    )
    OrchestratorTick.create!(
      run_id: run.run_id,
      phase: "planning",
      tick_count: 2,
      last_plan_summary: "Inspect the latest worker output.",
      pending_spawn_keys: [],
      following_steps: []
    )
    BusEvent.publish("run.status", run_id: run.run_id, payload: { runId: run.run_id, summary: "planning update" })
    artifact_path = File.join(workspace.root_path, "front", "demo-output", "agents-sdk", run.run_id, "fix-summary.md")
    FileUtils.mkdir_p(File.dirname(artifact_path))
    File.write(artifact_path, "First artifact line\nFinal artifact line that must remain visible\n")

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Test the details page.")
    expect(page).to have_text("What’s happening")
    expect(page).to have_text("Workers")
    expect(page).to have_text("Run Timeline")
    expect(page).to have_text("Artifacts")
    expect(page).to have_text("Run usage")
    expect(page).to have_text("Cost")
    expect(page).to have_text("planner-main")
    expect(page).to have_text("workflow-plan.md")
    expect(page).to have_text("fix-summary.md")
    expect(page).to have_text("Final artifact line that must remain visible")
  end

  it "navigates from an expanded worker to the full worker log" do
    workspace = create_workspace
    FileUtils.mkdir_p(File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers"))
    run = create_run(workspace:, suffix: "active-worker-link", task: "Jump straight to the active worker")
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "planner",
      nickname: "planner-live",
      reason: "Provide a prominent worker link.",
      scope: "workflow-plan.md",
      status: "running",
      pid: 321_123,
      prompt_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-live.prompt.txt"),
      log_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-live.log"),
      last_message_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-live.last-message.txt"),
      env_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner-live.env.json"),
      command: "claude",
      args: []
    )

    visit workspace_run_path(workspace, run)
    find("summary", text: "planner-live").click
    click_link "Open full worker log"

    expect(page).to have_current_path(workspace_worker_path(workspace, worker.worker_id))
    expect(page).to have_text("planner-live")
  end

  it "prioritizes active workers and surfaces unexpected exits with their latest output" do
    workspace = create_workspace
    workers_dir = File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers")
    FileUtils.mkdir_p(workers_dir)
    run = create_run(workspace:, suffix: "command-center", task: "Inspect the worker command center")
    stopped_worker = create_run_worker(run, nickname: "worker-history", status: "stopped", stop_reason: "Manually stopped from ops hub")
    attention_worker = create_run_worker(
      run,
      nickname: "worker-attention",
      status: "stopped",
      stop_reason: "Process no longer running after reconciliation."
    )
    running_worker = create_run_worker(run, nickname: "worker-active")
    File.write(attention_worker.last_message_path, "The request failed before the handoff completed.\n")

    visit workspace_run_path(workspace, run)

    worker_rows = all(".worker-row")
    expect(worker_rows.map { |row| row[:class] }).to eq([ "worker-row running", "worker-row attention", "worker-row stopped" ])
    expect(page).to have_text(stopped_worker.nickname)
    expect(page).to have_text(running_worker.nickname)

    find("summary", text: attention_worker.nickname).click
    expect(page).to have_text("needs attention")
    expect(page).to have_text("The request failed before the handoff completed.")
  end

  it "uses live worker evidence instead of a stale persisted phase" do
    workspace = create_workspace
    workers_dir = File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers")
    FileUtils.mkdir_p(workers_dir)
    run = create_run(workspace:, suffix: "live-over-phase", task: "Explain the live run clearly")
    run.update!(
      phase: "waiting_on_capacity",
      phase_summary: "Claude capacity is unavailable.",
      phase_updated_at: 5.minutes.ago,
      capacity_available_at: 20.minutes.from_now
    )
    worker = create_run_worker(run, nickname: "worker-live")
    worker.update!(scope: "diagnosis.md", reason: "Capture the request, refetch, and rendered state.")
    File.write(worker.last_message_path, "Recording the failing flow against backend port 4100.\n")
    OrchestratorTick.create!(
      run_id: run.run_id,
      phase: "planning",
      tick_count: 1,
      pending_spawn_keys: [],
      following_steps: [
        {
          owner: "worker",
          artifact: "verification.md",
          successCheck: "Verify the diagnosis evidence."
        }
      ]
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Work in progress")
    expect(page).to have_text("worker-live is working on diagnosis.md")
    expect(page).to have_text("Recording the failing flow against backend port 4100.")
    expect(page).to have_text("Capture the request, refetch, and rendered state.")
    expect(page).to have_text("verification.md")
    expect(page).to have_text("No. The run will continue automatically.")
    expect(page).to have_no_text("Work will resume automatically")
  end

  it "shows a blocking question when no worker is active" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "blocking-question", task: "Await an operator decision")
    run.user_questions.create!(
      asked_by: "worker",
      scope: "decision.md",
      text: "Which reproduction path should we take?",
      priority: "blocking",
      status: "open"
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Needs your decision")
    expect(page).to have_text("1 blocking question awaiting an answer.")
  end

  it "updates the run detail page live when new status and tick data arrive", :js do
    workspace = create_workspace
    run = create_run(
      workspace: workspace,
      suffix: "live-refresh",
      task: "Watch live updates arrive on the run page",
      status: "launching",
      started_at: nil
    )

    visit workspace_run_path(workspace, run)
    expect(page).to have_text("No worker lifecycle activity yet.")
    expect(page).to have_text("What’s happening")
    expect(page).to have_text("0")

    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        run.reload.update!(
          status: "running",
          phase: "planning",
          phase_owner: "planner",
          phase_summary: "The planner is deciding what to do next.",
          phase_updated_at: Time.current
        )
        OrchestratorTick.create!(
          run_id: run.run_id,
          phase: "planning",
          tick_count: 1,
          last_plan_summary: "Start by reproducing the slow path.",
          pending_spawn_keys: [],
          following_steps: []
        )
        BusEvent.publish(
          "run.status",
          run_id: run.run_id,
          payload: { runId: run.run_id, phase: "planning", owner: "planner", summary: "Planner woke up" }
        )
      end
    end

    expect(page).to have_text("What’s happening")
    expect(page).to have_text("planning")
    expect(page).to have_text("The planner is deciding what to do next.")
    expect(page).to have_text("Planning next step")

    publisher.join
  end

  it "kills an active run from the detail page" do
    workspace = create_workspace
    FileUtils.mkdir_p(File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers"))

    run = create_run(workspace:, suffix: "stop-run", task: "Stop this run from the UI")
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "planner",
      nickname: "planner",
      reason: "Testing run termination.",
      scope: "workflow-plan.md",
      status: "running",
      pid: 999_999,
      prompt_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner.prompt.txt"),
      log_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner.log"),
      last_message_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner.last-message.txt"),
      env_path: File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers", "planner.env.json"),
      command: "claude",
      args: []
    )

    visit workspace_run_path(workspace, run)
    click_button "Kill run"

    expect(page).to have_text("stopped")
    expect(page).to have_no_button("Kill run")
    expect(run.reload.status).to eq("stopped")
    expect(run.stopped_at).to be_present
    expect(worker.reload.status).to eq("stopped")
    expect(worker.stopped_at).to be_present
  end

  def create_workspace
    suffix = SecureRandom.hex(4)
    Workspace.create!(name: "planner-#{suffix}", root_path: "/tmp/planner-#{suffix}")
  end

  def create_run(workspace:, suffix:, task:, status: "running", started_at: Time.current)
    Run.create!(
      run_id: "demo-#{suffix}-#{SecureRandom.hex(4)}",
      task: task,
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: status,
      launched_by: "operator",
      started_at: started_at
    )
  end

  def create_run_worker(run, nickname:, status: "running", stop_reason: nil)
    workers_dir = File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers")
    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "worker",
      nickname: nickname,
      reason: "Inspect the worker command center.",
      scope: "fix-summary.md",
      status: status,
      pid: 123_456,
      prompt_path: File.join(workers_dir, "#{nickname}.prompt.txt"),
      log_path: File.join(workers_dir, "#{nickname}.log"),
      last_message_path: File.join(workers_dir, "#{nickname}.last-message.txt"),
      env_path: File.join(workers_dir, "#{nickname}.env.json"),
      command: "claude",
      args: [],
      stopped_at: status == "stopped" ? Time.current : nil,
      stop_reason: stop_reason
    )
  end
end
