require "rails_helper"

RSpec.describe McpTools::RequestGitRemovalTool do
  it "persists a request for a path that is actually part of the worktree's git status" do
    run, worker = create_run_and_worker
    git(run.target_root, "init")
    File.write(File.join(run.target_root, "stray.log"), "leftover\n")

    response = described_class.call(
      runId: run.run_id, path: "stray.log", reason: "leftover test-run output",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content[:status]).to eq("requested")
    expect(run.git_change_requests.sole.path).to eq("stray.log")
  end

  it "rejects a path that does not appear in real git status" do
    run, worker = create_run_and_worker
    git(run.target_root, "init")

    response = described_class.call(
      runId: run.run_id, path: "does-not-exist.txt", reason: "made up",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.git_change_requests).to be_empty
  end

  it "accepts a tracked ignored artifact that is absent from git status" do
    run, worker = create_run_and_worker
    git(run.target_root, "init")
    File.write(File.join(run.target_root, ".gitignore"), "*.log\n")
    File.write(File.join(run.target_root, "stale.log"), "leftover\n")
    git(run.target_root, "add", ".gitignore")
    git(run.target_root, "add", "-f", "stale.log")
    File.delete(File.join(run.target_root, "stale.log"))

    response = described_class.call(
      runId: run.run_id, path: "stale.log", reason: "old test output",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(run.git_change_requests.sole.path).to eq("stale.log")
  end

  it "rejects an unauthenticated caller" do
    run, = create_run_and_worker

    response = described_class.call(
      runId: run.run_id, path: "stray.log", reason: "leftover",
      server_context: { worker_id: "unknown" }
    )

    expect(response.error?).to be(true)
  end

  def git(root, *args)
    require "open3"
    _output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  end

  def create_run_and_worker
    root = Dir.mktmpdir("request-git-removal")
    workspace = Workspace.create!(name: "request-git-removal-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "request-git-removal-#{SecureRandom.hex(4)}", task: "Exercise request_git_removal",
      target_root: root, launcher_variant: "claude", status: "running",
      worktree_name: "request-git-removal-a1b2", branch_name: "workflow/request-git-removal-a1b2"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-#{SecureRandom.hex(2)}", reason: "test",
      scope: "artifact.md", status: "running", pid: 99_999, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end
