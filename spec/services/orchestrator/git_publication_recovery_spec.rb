require "rails_helper"

RSpec.describe Orchestrator::GitPublicationRecovery do
  it "requeues a fresh small-tier git worker after a single failed attempt" do
    run = create_run
    attempt = create_failed_attempt(run)

    result = described_class.call(attempt)

    expect(result).to eq(:requeued)
    fresh = run.spawn_requests.where(requested_role: "git", status: "open").sole
    expect(fresh.write_scope).to eq("git_managed")
    expect(fresh.allowed_paths).to eq([ "**/*" ])
    expect(fresh.model_tier).to eq("small")
    expect(ChaperoneReview.where(run_id: run.run_id)).to be_empty
    expect(run.reload.phase).to eq("planning")
  end

  it "escalates to the chaperone instead of requeuing once failures cross the normal threshold" do
    run = create_run
    create_failed_attempt(run)
    attempt = create_failed_attempt(run)

    result = described_class.call(attempt)

    expect(result).to be_a(ChaperoneReview)
    expect(run.spawn_requests.where(requested_role: "chaperone").count).to eq(1)
  end

  it "keeps worker_turn from requesting a doomed planner follow-up for a blocked git worker" do
    run = create_run
    worker = create_worker(run, status: "running")
    request = run.spawn_requests.create!(
      asked_by: "orchestrator", requested_role: "git", scope: "publish-#{run.worktree_name}.md",
      write_scope: "git_managed", allowed_paths: [ "**/*" ], model_tier: "small",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Commit, rebase, push, and publish.", priority: "blocking", execution_mode: "implementation"
    )

    response = Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "git", nickname: worker.nickname, scope: request.scope,
      result: "[BLOCKED] Rebase conflict is genuinely ambiguous."
    )

    expect(response[:planner_request]).to be_nil
    expect(response).not_to have_key(:chaperone_review)
    expect(run.spawn_requests.where(requested_role: "planner", status: "open")).to be_empty
    expect(run.spawn_requests.where(requested_role: "git", status: "open").count).to eq(1)
  end

  private

  def create_run
    workspace = Workspace.create!(name: "git-recovery-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.runs.create!(
      run_id: "git-recovery-#{SecureRandom.hex(4)}", task: "Exercise git publication recovery",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "git-recovery-a1b2", branch_name: "workflow/git-recovery-a1b2"
    )
  end

  def create_worker(run, status:)
    id = SecureRandom.uuid
    run.workers.create!(
      worker_id: id, role: "git", nickname: "git-#{id.first(6)}", reason: "Publish.",
      scope: "publish-#{run.worktree_name}.md", status:, pid: 999_999_999,
      prompt_path: "/tmp/#{id}.prompt", log_path: "/tmp/#{id}.log", last_message_path: "/tmp/#{id}.last",
      env_path: "/tmp/#{id}.env", command: "claude", write_scope: "git_managed", allowed_paths: [ "**/*" ]
    )
  end

  def create_failed_attempt(run)
    worker = create_worker(run, status: "stopped")
    request = run.spawn_requests.create!(
      asked_by: "orchestrator", requested_role: "git", scope: "publish-#{run.worktree_name}.md",
      write_scope: "git_managed", allowed_paths: [ "**/*" ], model_tier: "small",
      status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Commit, rebase, push, and publish.", priority: "blocking", execution_mode: "implementation"
    )
    StepAttempt.create!(
      run:, spawn_request: request, worker_id: worker.worker_id,
      lineage_key: request.scope, mode: "implementation",
      outcome: "failed", result: "Worker exited with status 0 before completing its handoff.",
      evidence_citations: []
    )
  end
end
