require "rails_helper"

RSpec.describe WorkerReconcileJob do
  it "retries a reply_received worker once when it exits before submitting its decision" do
    workspace = Workspace.create!(name: "reconcile-reply-retry-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(workspace:, run_id: "reconcile-reply-retry-#{SecureRandom.hex(4)}", task: "Classify a reply", target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    question = run.user_questions.create!(asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking", text: "Review this PR")
    review, = ReplyReceivedReview.issue!(run:, user_question: question, comment: { "id" => 1, "body" => "Please revise", "user" => { "login" => "operator" } })
    log_path = File.join(workspace.root_path, "reply.log")
    File.write(log_path, "The required MCP tools are unavailable.\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "reply_received", nickname: "reply-retry",
      reason: "Classify reply", scope: review.review_id, status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "codex"
    )
    run.spawn_requests.create!(
      asked_by: "github_pr_comment", requested_role: "reply_received", priority: "blocking", scope: review.review_id,
      lineage_key: review.review_id, text: "Classify reply", status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )

    described_class.perform_now

    retry_request = run.spawn_requests.find_by!(asked_by: "reply_received_recovery")
    expect(retry_request).to have_attributes(requested_role: "reply_received", scope: review.review_id, lineage_key: review.review_id, status: "open")
    expect(review.reload.status).to eq("queued")
    expect(run.reload.phase).to eq("planning")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "classifies a Claude session-limit exit from the worker log" do
    workspace = Workspace.create!(name: "reconcile-test-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "reconcile-test-#{SecureRandom.hex(4)}",
      task: "Test worker reconciliation",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, <<~LOG)
      You've hit your session limit · resets 5pm (Europe/Paris)
      {"type":"result","model":"claude-haiku-4-5","num_turns":3,"total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}
    LOG
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "worker",
      nickname: "worker-test",
      reason: "Test worker",
      scope: "test.md",
      status: "running",
      pid: 999_999_999,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      env_path: log_path,
      command: "claude"
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Claude session limit reached; worker exited before completing its handoff.", worker.stop_reason
    assert_equal "claude-haiku-4-5", worker.model
    assert_equal 3, worker.agent_turn_count
    assert_equal 30, worker.cache_read_input_tokens
    assert_includes worker.as_json[:outputTail], "session limit"
    assert_operator run.reload.capacity_available_at, :>, Time.current
    assert_equal "waiting_on_capacity", run.phase
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "classifies a Codex usage-limit exit from the worker log and parses its absolute reset time" do
    workspace = Workspace.create!(name: "reconcile-codex-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "reconcile-codex-#{SecureRandom.hex(4)}",
      task: "Test worker reconciliation",
      target_root: workspace.root_path,
      launcher_variant: "codex",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    reset_at = 3.days.from_now.change(hour: 19, min: 3)
    File.write(log_path, <<~LOG)
      ERROR: You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at #{reset_at.strftime('%b')} #{reset_at.day}th, #{reset_at.year} #{reset_at.strftime('%-I:%M %p')}.
    LOG
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "git",
      nickname: "git-test",
      reason: "Test worker",
      scope: "test.md",
      status: "running",
      pid: 999_999_998,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      env_path: log_path,
      command: "codex"
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Codex usage limit reached; worker exited before completing its handoff.", worker.stop_reason
    run.reload
    assert_operator run.capacity_available_at, :>, Time.current
    assert_in_delta reset_at, run.capacity_available_at, 1.minute
    assert_equal "waiting_on_capacity", run.phase
    assert run.capacity_blocked?
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "bounds stream-log diagnostics returned to planners" do
    directory = Dir.mktmpdir
    log_path = File.join(directory, "worker.log")
    File.write(log_path, "x" * 2_000)
    worker = Worker.allocate
    worker.define_singleton_method(:log_path) { log_path }

    assert_equal 1_203, worker.send(:output_tail).length
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  it "does not report a failed handoff after a worker has completed one" do
    workspace = Workspace.create!(name: "reconcile-handoff-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "reconcile-handoff-#{SecureRandom.hex(4)}",
      task: "Test completed handoff reconciliation",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "completed\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "planner",
      nickname: "planner-test",
      reason: "Test planner",
      scope: "workflow-plan.md",
      status: "running",
      pid: 999_999_999,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      exit_status_path: log_path,
      env_path: log_path,
      command: "claude",
      handoff_completed_at: Time.current
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Worker stopped after completing its handoff.", worker.stop_reason
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "persists Claude's final response for the worker view" do
    workspace = Workspace.create!(name: "reconcile-final-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-final-#{SecureRandom.hex(4)}", task: "Persist final response",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    last_message_path = File.join(workspace.root_path, "worker.last-message.txt")
    File.write(log_path, { type: "result", result: "The verification completed.", usage: {} }.to_json << "\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "worker", nickname: "worker-final",
      reason: "Verify it.", scope: "verification.md", status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path:, env_path: log_path, command: "claude"
    )

    WorkerReconcileJob.perform_now

    expect(File.read(last_message_path)).to eq("The verification completed.\n")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "persists cost/usage for a chaperone worker, not just ordinary workers" do
    workspace = Workspace.create!(name: "reconcile-chaperone-cost-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-chaperone-cost-#{SecureRandom.hex(4)}", task: "Track chaperone cost",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, <<~LOG)
      {"type":"result","model":"claude-sonnet-5","num_turns":4,"total_cost_usd":0.35,"result":"Decision submitted: continue_small.","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400}}
    LOG
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "chaperone", nickname: "chaperone-cost-test",
      reason: "Chaperone review.", scope: "diagnose-it", status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )

    WorkerReconcileJob.perform_now

    worker.reload
    assert_equal "stopped", worker.status
    assert_equal 0.35, worker.total_cost_usd
    assert_equal 200, worker.output_tokens
    assert_equal "Decision submitted: continue_small.\n", File.read(worker.last_message_path)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "recovers a dead verifier by re-requesting verification instead of chaperone/planner recovery" do
    workspace = Workspace.create!(name: "reconcile-verifier-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-verifier-#{SecureRandom.hex(4)}", task: "Recover a dead verifier",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    criterion = AcceptanceCriterion.create!(
      run_id: run.run_id, key: "outcome-works", content: "The outcome works.",
      status: "ready_for_verification", evidence_ref: "Gemfile"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "verifier narrated success but never submitted\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "verifier", nickname: "verifier",
      reason: "Verify.", scope: "acceptance-verify-#{criterion.key}", status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )
    run.spawn_requests.create!(
      asked_by: "planner", requested_role: "verifier", scope: worker.scope,
      lineage_key: "acceptance:#{criterion.key}", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Verify it.", priority: "blocking", execution_mode: "verification"
    )

    WorkerReconcileJob.perform_now

    expect(worker.reload.status).to eq("stopped")
    fresh = run.spawn_requests.where(requested_role: "verifier", status: "open").sole
    expect(fresh.scope).to eq("acceptance-verify-#{criterion.key}")
    expect(ChaperoneReview.where(run_id: run.run_id)).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "records a normal stop for a chaperone worker that died after submitting its decision" do
    workspace = Workspace.create!(name: "reconcile-chaperone-done-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-chaperone-done-#{SecureRandom.hex(4)}", task: "Reconcile a finished chaperone",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "decision submitted\n")
    review = ChaperoneReview.create!(
      run:, lineage_key: "diagnosis-lineage", step_attempt_ids: [], status: "completed",
      action: "continue_small", summary: "Bounded retry is sufficient.", token_digest: SecureRandom.hex(32),
      expires_at: 1.hour.from_now, completed_at: Time.current
    )
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "chaperone", nickname: "chaperone-test",
      reason: "Chaperone review.", scope: review.lineage_key, status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )
    run.spawn_requests.create!(
      asked_by: "chaperone", scope: review.lineage_key, lineage_key: review.lineage_key,
      text: "Repeated blocked diagnosis.", requested_role: "chaperone", priority: "blocking",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "completed", review.reload.status
    expect(StepAttempt.where(worker_id: worker.worker_id)).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "fails the review and asks the operator when a chaperone worker dies before deciding" do
    workspace = Workspace.create!(name: "reconcile-chaperone-dead-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-chaperone-dead-#{SecureRandom.hex(4)}", task: "Reconcile a killed chaperone",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "\n")
    diagnosis_request = run.spawn_requests.create!(
      asked_by: "planner", scope: "diagnosis.md", text: "Diagnose it.", requested_role: "worker",
      priority: "blocking", lineage_key: "diagnosis-lineage"
    )
    attempt = StepAttempt.create!(
      run:, spawn_request: diagnosis_request, worker_id: SecureRandom.uuid, lineage_key: "diagnosis-lineage",
      mode: "diagnosis", outcome: "blocked", result: "Could not reproduce.", chaperone_status: "queued"
    )
    review = ChaperoneReview.create!(
      run:, lineage_key: "diagnosis-lineage", step_attempt_ids: [ attempt.attempt_id ], status: "running",
      token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now, started_at: Time.current
    )
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "chaperone", nickname: "chaperone-test",
      reason: "Chaperone review.", scope: review.lineage_key, status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )
    run.spawn_requests.create!(
      asked_by: "chaperone", scope: review.lineage_key, lineage_key: review.lineage_key,
      text: "Repeated blocked diagnosis.", requested_role: "chaperone", priority: "blocking",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "failed", review.reload.status
    question = UserQuestion.find_by(run_id: run.run_id, priority: "blocking", status: "open")
    expect(question).to be_present
    assert_equal "awaiting_user_feedback", run.reload.phase
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "pauses the run for capacity instead of failing a rate-limited chaperone review" do
    workspace = Workspace.create!(name: "reconcile-chaperone-capacity-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-chaperone-capacity-#{SecureRandom.hex(4)}", task: "Reconcile a rate-limited chaperone",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "You've hit your session limit · resets 5pm (Europe/Paris)\n")
    review = ChaperoneReview.create!(
      run:, lineage_key: "diagnosis-lineage", step_attempt_ids: [], status: "running",
      token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now, started_at: Time.current
    )
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "chaperone", nickname: "chaperone-test",
      reason: "Chaperone review.", scope: review.lineage_key, status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )
    run.spawn_requests.create!(
      asked_by: "chaperone", scope: review.lineage_key, lineage_key: review.lineage_key,
      text: "Repeated blocked diagnosis.", requested_role: "chaperone", priority: "blocking",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "running", review.reload.status
    assert_nil UserQuestion.find_by(run_id: run.run_id, priority: "blocking", status: "open")
    assert_operator run.reload.capacity_available_at, :>, Time.current
    assert_equal "waiting_on_capacity", run.phase
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "records a normal stop for a project_init worker that already recorded the primary finding" do
    workspace = Workspace.create!(name: "reconcile-project-init-done-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-project-init-done-#{SecureRandom.hex(4)}", task: "Reconcile a finished project_init",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "findings recorded\n")
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "project_init", nickname: "project-init-test",
      reason: "Discover the dev environment.", scope: "project-setup", status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )
    run.spawn_requests.create!(
      asked_by: "orchestrator", scope: "project-setup", lineage_key: "project-init:#{workspace.id}",
      text: "Discover the dev environment.", requested_role: "project_init", priority: "blocking",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Project setup discovery completed and recorded its findings.", worker.stop_reason
    expect(StepAttempt.where(worker_id: worker.worker_id)).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "completes a workspace_init bootstrap run once project_init has declared protected paths too" do
    workspace = Workspace.create!(
      name: "reconcile-bootstrap-done-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir,
      protected_path_patterns: [ "app/controllers/**/*.rb" ]
    )
    run = Run.create!(
      workspace:, run_id: "reconcile-bootstrap-done-#{SecureRandom.hex(4)}", task: Orchestrator::WorkspaceInit::TASK,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running", launched_by: "workspace_init"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "findings recorded\n")
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )
    Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "project_init", nickname: "project-init-test",
      reason: "Discover the dev environment.", scope: "project-setup", status: "running", pid: 999_999_988,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )

    WorkerReconcileJob.perform_now

    run.reload
    assert_equal "completed", run.status
    assert_equal "completed", run.phase
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "stops (not completes) a workspace_init bootstrap run when only the dev-environment finding landed, not protected paths" do
    workspace = Workspace.create!(name: "reconcile-bootstrap-partial-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-bootstrap-partial-#{SecureRandom.hex(4)}", task: Orchestrator::WorkspaceInit::TASK,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running", launched_by: "workspace_init"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "findings recorded\n")
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run `bin/dev` from the repository root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )
    Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "project_init", nickname: "project-init-test",
      reason: "Discover the dev environment.", scope: "project-setup", status: "running", pid: 999_999_987,
      prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
    )

    WorkerReconcileJob.perform_now

    run.reload
    assert_equal "stopped", run.status
    assert_equal "awaiting_user_feedback", run.phase
    refute workspace.reload.initialized?
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "records a failed attempt and escalates to chaperone after repeated project_init failures" do
    workspace = Workspace.create!(name: "reconcile-project-init-fail-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-project-init-fail-#{SecureRandom.hex(4)}", task: "Reconcile a failed project_init",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "crashed before recording anything\n")

    2.times do |i|
      worker = Worker.create!(
        worker_id: SecureRandom.uuid, run_id: run.run_id, role: "project_init", nickname: "project-init-test-#{i}",
        reason: "Discover the dev environment.", scope: "project-setup", status: "running", pid: 999_999_990 + i,
        prompt_path: log_path, log_path:, last_message_path: log_path, env_path: log_path, command: "claude"
      )
      run.spawn_requests.create!(
        asked_by: "orchestrator", scope: "project-setup", lineage_key: "project-init:#{workspace.id}",
        text: "Discover the dev environment.", requested_role: "project_init", priority: "blocking",
        execution_mode: "diagnosis", write_scope: "source_protected",
        status: "fulfilled", fulfilled_worker_id: worker.worker_id
      )

      WorkerReconcileJob.perform_now
    end

    assert_equal 2, StepAttempt.where(lineage_key: "project-init:#{workspace.id}").count
    assert run.chaperone_reviews.exists?(lineage_key: "project-init:#{workspace.id}", status: "queued")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "diagnostic worker payload excludes the launch prompt" do
    directory = Dir.mktmpdir
    log_path = File.join(directory, "worker.log")
    File.write(log_path, "worker output\n")
    worker = Worker.new(
      worker_id: "worker-id",
      run_id: "run-id",
      role: "worker",
      nickname: "worker",
      scope: "report.md",
      status: "stopped",
      started_at: Time.current,
      log_path: log_path,
      args: [ "very large prompt" ]
    )

    payload = worker.as_diagnostic_json

    assert_not payload.key?(:args)
    assert_not payload.key?(:promptPath)
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end
end
