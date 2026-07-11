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
    expect(page).to have_text("Current Phase")
    expect(page).to have_text("Recent Signals")
    expect(page).to have_text("spawn_request.created")
  end

  it "opens the detail page from the workspace run list" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "detail-open", task: "Inspect the orchestrator detail page")

    visit workspace_runs_path(workspace)
    click_link run.run_id

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.task)
    expect(page).to have_text("Current Phase")
    expect(page).to have_text("Recent Signals")
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

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("phase: planning")
    expect(page).to have_text("owner: planner")
    expect(page).to have_text("Choosing the next step.")
    expect(page).to have_text("Current Phase")
    expect(page).to have_text("Live Worker")
    expect(page).to have_link("Open active worker", href: workspace_worker_path(workspace, run.workers.first.worker_id))
    expect(page).to have_text("Recent Signals")
    expect(page).to have_text("Artifacts")
    expect(page).to have_text("planning update")
    expect(page).to have_text("planner-main")
    expect(page).to have_text("workflow-plan.md")
    expect(page).to have_text("fix-summary.md")
    expect(page).to have_text("Tick 2")
    expect(page).to have_text("Inspect the latest worker output.")
  end

  it "navigates from the run page to the active worker page" do
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
    click_link "Open active worker"

    expect(page).to have_current_path(workspace_worker_path(workspace, worker.worker_id))
    expect(page).to have_text("planner-live")
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
    expect(page).to have_text("No non-status events yet.")
    expect(page).to have_text(/latest tick/i)
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

    expect(page).to have_text(/latest tick/i)
    expect(page).to have_text("planning")
    expect(page).to have_text("The planner is deciding what to do next.")
    expect(page).to have_text("running")

    publisher.join
  end

  it "keeps expanded accordions open across live tick refreshes", :js do
    workspace = create_workspace
    run = create_run(
      workspace: workspace,
      suffix: "accordion-refresh",
      task: "Keep the activity feed open during live updates"
    )
    BusEvent.publish("run.status", run_id: run.run_id, payload: { runId: run.run_id, summary: "initial status" })

    visit workspace_run_path(workspace, run)

    find("summary", text: "Raw activity feed").click
    expect(page).to have_css("details[open] summary", text: "Raw activity feed", visible: :all)

    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        OrchestratorTick.create!(
          run_id: run.run_id,
          phase: "planning",
          tick_count: 1,
          last_plan_summary: "Refresh while the accordion is open.",
          pending_spawn_keys: [],
          following_steps: []
        )
        BusEvent.publish(
          "run.status",
          run_id: run.run_id,
          payload: { runId: run.run_id, phase: "planning", summary: "live update landed" }
        )
      end
    end

    expect(page).to have_text("live update landed")
    expect(page).to have_css("details[open] summary", text: "Raw activity feed", visible: :all)

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
end
