require "rails_helper"

RSpec.describe "workspace runs", type: :system do
  it "launches a run and lands on the workspace-scoped detail page" do
    workspace = create_workspace(source_checkout: true)

    visit workspace_runs_path(workspace)
    click_link "Launch task"
    fill_in "Task", with: "Investigate the slow recorded phone demo"

    perform_enqueued_jobs do
      click_button "Launch"
    end

    run = Run.order(:created_at).last

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.run_id)
    expect(page).to have_text(workspace.name)
  end

  it "opens the detail page from the workspace run list" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "detail-open", task: "Inspect the orchestrator detail page")

    visit workspace_runs_path(workspace)
    click_link run.run_id

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.task)
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

  it "loads the run detail page while a run is waiting for capacity" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "capacity-switch", task: "Continue after capacity returns")
    run.update!(capacity_available_at: 30.minutes.from_now)

    visit workspace_run_path(workspace, run)

    expect(page).to have_current_path(workspace_run_path(workspace, run))
    expect(page).to have_text(run.run_id)
    expect(page).to have_text("Waiting for capacity")
    expect(page).to have_text("The next model call will retry automatically after")
    expect(page).to have_button("Switch to Codex & resume")
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
    artifact_path = Orchestrator::ArtifactStore.resolve_path(workspace.root_path, run.run_id, "fix-summary.md")
    FileUtils.mkdir_p(File.dirname(artifact_path))
    File.write(artifact_path, "First artifact line\nFinal artifact line that must remain visible\n")

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Test the details page.")
    expect(page).to have_text("Workflow tree")
    expect(page).to have_css("[data-testid='workflow-tree']")
    expect(page).to have_no_css(".acceptance-criteria-panel")
    expect(page).to have_no_css(".planner-history")
    expect(page).to have_text("Other work")
    expect(page).to have_text("Artifacts")
    expect(page).to have_text("Usage & planner")
    expect(page).to have_text("Cost")
    expect(page).to have_text("planner-main")
    expect(page).to have_text("workflow-plan.md")
    expect(page).to have_text("fix-summary.md")
    expect(page).to have_text("Final artifact line that must remain visible")
  end

  it "intermeshes a planner, its criteria, and assigned workers in one tree" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "workflow-tree", task: "Show the unified workflow hierarchy")
    criterion = run.acceptance_criteria.create!(key: "ui-hierarchy", content: "The workflow hierarchy is visible", status: "in_progress")
    worker = create_run_worker(run, nickname: "criterion-worker")
    request = run.spawn_requests.create!(
      request_id: SecureRandom.uuid, asked_by: "planner", requested_role: "worker", scope: "ui-hierarchy",
      text: "Implement the hierarchy", status: "fulfilled", priority: "advisory", fulfilled_worker_id: worker.worker_id,
      lineage_key: "criterion:ui-hierarchy"
    )
    criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: request.lineage_key)

    visit workspace_run_path(workspace, run)

    expect(page).to have_css("[data-testid='workflow-tree']")
    tree = find("[data-testid='workflow-tree']")
    expect(tree).to have_text("Workflow planner")
    expect(tree).to have_text("ui-hierarchy")
    expect(tree).to have_css(".workflow-criterion-node .worker-row", text: "criterion-worker")
    expect(tree.text.index("Workflow planner")).to be < tree.text.index("ui-hierarchy")
  end

  it "nests planner workers under their criterion in execution order without duplicating them at the root" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "nested-workflow-tree", task: "Show nested planner execution")
    root_criterion = run.acceptance_criteria.create!(
      key: "parent-work",
      content: "The parent work is visible",
      status: "in_progress"
    )
    child_criterion = run.acceptance_criteria.create!(
      key: "nested-work",
      content: "The nested work is visible",
      status: "in_progress",
      parent: root_criterion
    )
    nested_planner = create_run_worker(run, nickname: "nested-planner", role: "planner")
    nested_request = run.spawn_requests.create!(
      request_id: SecureRandom.uuid, asked_by: "planner", requested_role: "planner", scope: "parent-work",
      text: "Plan the nested work", status: "fulfilled", priority: "blocking",
      fulfilled_worker_id: nested_planner.worker_id, lineage_key: "criterion:parent-work"
    )
    root_criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: nested_request.lineage_key)
    child_worker = create_run_worker(run, nickname: "nested-worker")
    child_request = run.spawn_requests.create!(
      request_id: SecureRandom.uuid, asked_by: "nested-planner", requested_role: "worker", scope: "nested-work",
      text: "Implement the nested work", status: "fulfilled", priority: "advisory",
      fulfilled_worker_id: child_worker.worker_id, lineage_key: "criterion:nested-work"
    )
    child_criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: child_request.lineage_key)

    visit workspace_run_path(workspace, run)

    trees = all("[data-testid='workflow-tree']")
    tree = trees.first
    tree_text = tree.text
    expect(tree_text).to include("nested-planner", "nested-work", "nested-worker")
    expect(tree_text.scan("nested-planner").length).to eq(1)
    root_planners = tree.all(
      :xpath,
      "./li[contains(concat(' ', normalize-space(@class), ' '), ' workflow-planner-node ')]"
    )
    expect(root_planners.length).to eq(1)
    expect(root_planners.first.all(".workflow-tree-label strong").first.text).to eq("Workflow planner")
    expect(tree_text.index("parent-work")).to be < tree_text.index("nested-planner")
    expect(tree_text.index("nested-planner")).to be < tree_text.index("nested-work")
    expect(tree_text.index("nested-work")).to be < tree_text.index("nested-worker")
  end

  it "shows a run-scoped background command and can stop it from the dashboard" do
    workspace = create_workspace
    FileUtils.mkdir_p(workspace.root_path)
    run = create_run(workspace:, suffix: "run-commands", task: "Show run commands on the dashboard")
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/sleep", arguments: [ "30" ],
      purpose: "keep a dev server alive for verification"
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Run commands")
    expect(page).to have_text("keep a dev server alive for verification")
    expect(page).to have_text("running")

    find("summary", text: "Run commands").click
    find("summary", text: "keep a dev server alive for verification").click
    click_button "Stop"

    expect(page).to have_text("Run command stopped.")
    expect(command.reload.status).to eq("stopped")
  end

  it "renders every persisted planner decision with its attempts and context" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "planner-history", task: "Explain every planning decision")
    launch_request = run.spawn_requests.create!(
      asked_by: "operator", requested_role: "planner", scope: "workflow-plan.md",
      text: "Choose the initial step.", status: "fulfilled", priority: "blocking", tags: %w[launch]
    )
    first = run.planner_decisions.create!(
      spawn_request: launch_request, status: "completed", model: "claude-haiku", model_calls: 1,
      input_tokens: 800, output_tokens: 120, total_cost_usd: 0.01, context_bytes: 600,
      context_requests: [
        { source: "artifact", reference: "diagnosis.md", question: "What failed?", max_chars: 600, returned_bytes: 600 }
      ],
      decision: {
        summary: "Gather direct runtime evidence.",
        next_step: {
          owner: "worker", artifact: "diagnosis.md", mode: "diagnosis", write_scope: "source_protected",
          success_check: "Reproduce the failure.", allowed_paths: [], evidence_refs: []
        },
        following_steps: []
      },
      started_at: 4.minutes.ago, completed_at: 3.minutes.ago
    )
    first.attempts.create!(
      sequence: 1, model_tier: "small", model: "claude-haiku", outcome: "decision", disposition: "accepted",
      proposal: { summary: "Gather direct runtime evidence.", next_step: first.decision["next_step"] },
      usage: { input_tokens: 800, output_tokens: 120, total_cost_usd: 0.01 }
    )

    retry_request = run.spawn_requests.create!(
      asked_by: "worker-2", requested_role: "planner", scope: "workflow-plan.md",
      text: "Recover from a rejected handoff.", status: "fulfilled", priority: "blocking"
    )
    second = run.planner_decisions.create!(
      spawn_request: retry_request, status: "failed", model: "claude-haiku", model_calls: 1,
      input_tokens: 300, output_tokens: 40, total_cost_usd: 0.004,
      error: "Policy rejected exact path", started_at: 2.minutes.ago, completed_at: 1.minute.ago
    )
    second.attempts.create!(
      sequence: 1, model_tier: "small", model: "claude-haiku", outcome: "decision", disposition: "rejected",
      rejection_reason: "Policy rejected exact path", proposal: { summary: "Broaden the write scope." },
      usage: { input_tokens: 300, output_tokens: 40, total_cost_usd: 0.004 }
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("2 planner decisions")
    rows = all(".planner-decision-row", visible: :all)
    expect(rows.count).to eq(2)
    expect(rows.first.text(:all)).to include("Decision 2", "Failed before a decision")
    expect(page).to have_css(".planner-decision-row", text: "Policy rejected exact path", visible: :all)
    expect(page).to have_css(".planner-decision-row", text: "artifact:diagnosis.md", visible: :all)
    expect(page).to have_css(".planner-decision-row", text: "worker → diagnosis.md", visible: :all)
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
    expect(page).to have_text("planner-live")
    
    expect(page).to have_text("planner-live")
    expect(page).to have_text("Workflow tree")
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

    worker_rows = all(".worker-row", visible: :all)
    expect(worker_rows.map { |row| row[:class] }).to eq([ "worker-row running", "worker-row attention", "worker-row stopped" ])
    expect(page).to have_text(stopped_worker.nickname)
    expect(page).to have_text(running_worker.nickname)

    expect(page).to have_text("needs attention")
    expect(page).to have_css(
      ".worker-row.attention", text: "The request failed before the handoff completed.", visible: :all
    )
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
    File.write(worker.log_path, [
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Located the recorded phone scenario." } ] } }.to_json,
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Measuring the 29-step recording now." } ] } }.to_json
    ].join("\n"))
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

    expect(page).to have_text("Recording the failing flow against backend port 4100.")
    expect(page).to have_text("Capture the request, refetch, and rendered state.")
    expect(page).to have_no_text("Waiting for capacity")
  end

  it "prioritizes a blocking question even while a worker is active" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "blocking-question", task: "Await an operator decision")
    create_run_worker(run, nickname: "worker-still-active")
    run.user_questions.create!(
      asked_by: "worker",
      scope: "decision.md",
      text: "Which reproduction path should we take?",
      priority: "blocking",
      status: "open"
    )

    visit workspace_run_path(workspace, run)

    within("[data-testid='run-state-header']") do
      expect(page).to have_text("Question needs your answer")
      expect(page).to have_text("Which reproduction path should we take?")
    end
    expect(page).to have_text("Operator Input Required")
    expect(page).to have_text("1 blocking question")
    expect(page).to have_text("The run will remain paused until these questions are answered.")
    expect(page).to have_no_text("No action required while the worker is making progress.")
  end

  it "shows an explicit failure while retaining the stopped worker progress trail" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "failed-narrative", task: "Explain a failed run")
    run.update!(status: "failed", phase: "failed", phase_summary: "Planner contract validation failed.")
    worker = create_run_worker(run, nickname: "worker-failed", status: "stopped", stop_reason: "Handoff failed")
    FileUtils.mkdir_p(File.dirname(worker.log_path))
    File.write(worker.log_path,
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Backend rejected the recording request." } ] } }.to_json)

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("worker-failed")
    expect(page).to have_text("Handoff failed")
  end

  it "displays the run detail page with worker data when handoff is rejected" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "handoff-rejected", task: "Explain a rejected handoff")
    create_run_worker(run, nickname: "worker-1", status: "stopped", stop_reason: "Handoff failed")
    BusEvent.publish(
      "worker.handoff_rejected", run_id: run.run_id,
      payload: { nickname: "worker-1", error: "diagnosis evidenceCitation not found in diagnosis.md: paraphrase" }
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Workflow tree")
  end

  it "hides a handoff rejection the same worker went on to self-correct" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "handoff-self-corrected", task: "Explain a self-corrected handoff")
    create_run_worker(run, nickname: "worker-1", status: "stopped", handoff_completed_at: Time.current)
    BusEvent.publish(
      "worker.handoff_rejected", run_id: run.run_id,
      payload: { nickname: "worker-1", error: "diagnosis evidenceCitation not found in diagnosis.md: paraphrase" }
    )

    visit workspace_run_path(workspace, run)

    expect(page).to have_text("Workflow tree")
  end

  it "keeps a handoff rejection visible when that worker never completed a handoff" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "handoff-never-corrected", task: "Explain a stuck handoff")
    create_run_worker(run, nickname: "worker-1", status: "stopped", stop_reason: "Handoff failed")
    BusEvent.publish(
      "worker.handoff_rejected", run_id: run.run_id,
      payload: { nickname: "worker-1", error: "diagnosis evidenceCitation not found in diagnosis.md: paraphrase" }
    )

    visit workspace_run_path(workspace, run)
    expect(page).to have_text("Workflow tree")
  end

  it "shows one chaperone review rather than its worker lifecycle as separate reviews" do
    workspace = create_workspace
    run = create_run(workspace:, suffix: "single-chaperone", task: "Clarify the chaperone timeline")
    review, = ChaperoneReview.issue!(run:, lineage_key: "criterion:checkout", step_attempt_ids: [])
    review.update!(status: "completed", action: "continue_small", completed_at: Time.current, summary: "Use the documented toolchain.")
    worker = create_run_worker(run, nickname: "chaperone-test", status: "stopped", stop_reason: "Worker exited with status 0 before completing its handoff.")
    worker.update!(role: "chaperone", scope: "criterion:checkout")
    run.spawn_requests.create!(
      request_id: SecureRandom.uuid,
      asked_by: "chaperone",
      requested_role: "chaperone",
      scope: "criterion:checkout",
      text: "Chaperone review for lineage criterion:checkout.",
      lineage_key: "criterion:checkout",
      status: "fulfilled",
      priority: "blocking",
      fulfilled_worker_id: worker.worker_id
    )
    BusEvent.publish("worker.spawned", run_id: run.run_id, payload: { role: "chaperone", nickname: worker.nickname })
    BusEvent.publish("worker.stopped", run_id: run.run_id, payload: { role: "chaperone", nickname: worker.nickname })

    visit workspace_run_path(workspace, run)

    expect(page).to have_css(".worker-name", text: "Chaperone review", count: 1)
    expect(page).to have_text("Decision: Continue small")
    expect(page).not_to have_text("chaperone-test started")
    expect(page).not_to have_text("chaperone-test stopped")
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
    expect(page).to have_text("0")

    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        run.reload.update!(
          status: "running",
          phase: "planning",
          phase_owner: "orchestrator",
          phase_summary: "Claude capacity is unavailable.",
          capacity_available_at: 20.minutes.from_now,
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
          payload: { runId: run.run_id, phase: "waiting_on_capacity", owner: "orchestrator", summary: "Claude capacity is unavailable." }
        )
      end
    end

    expect(page).to have_text("Waiting for capacity")
    expect(page).to have_text("Claude capacity is unavailable.")

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

  def create_workspace(source_checkout: false)
    suffix = SecureRandom.hex(4)
    root_path = source_checkout ? create_source_checkout : "/tmp/planner-#{suffix}"
    Workspace.create!(
      name: "planner-#{suffix}", root_path: root_path,
      protected_path_patterns: [ "app/controllers/**/*.rb" ]
    )
  end

  def create_source_checkout
    parent = Dir.mktmpdir("workflow-system-source")
    main = File.join(parent, "main")
    FileUtils.mkdir_p(main)
    system("git", "-C", main, "init", "-b", "main", out: File::NULL, err: File::NULL) || raise("could not initialize source checkout")
    system("git", "-C", main, "config", "user.email", "system-spec@example.test")
    system("git", "-C", main, "config", "user.name", "System Spec")
    File.write(File.join(main, "README.md"), "isolated launch fixture\n")
    system("git", "-C", main, "add", "README.md") || raise("could not stage source checkout")
    system("git", "-C", main, "commit", "-m", "Initialize system spec checkout", out: File::NULL, err: File::NULL) || raise("could not commit source checkout")
    system("git", "-C", main, "remote", "add", "origin", "https://example.test/workflow.git") || raise("could not configure source checkout remote")
    parent
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

  def create_run_worker(run, nickname:, role: "worker", status: "running", stop_reason: nil, handoff_completed_at: nil)
    workers_dir = File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers")
    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: role,
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
      stop_reason: stop_reason,
      handoff_completed_at: handoff_completed_at
    )
  end
end
