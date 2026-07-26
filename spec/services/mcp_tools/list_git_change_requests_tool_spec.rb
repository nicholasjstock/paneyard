require "rails_helper"

RSpec.describe McpTools::ListGitChangeRequestsTool do
  it "lists a run's git change requests for the authenticated committer" do
    root = Dir.mktmpdir("list-git-change-requests")
    workspace = Workspace.create!(name: "list-git-change-requests-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "list-git-change-requests-#{SecureRandom.hex(4)}", task: "List git change requests",
      target_root: root, launcher_variant: "claude", status: "running",
      worktree_name: "list-a1b2", branch_name: "workflow/list-a1b2"
    )
    run.git_change_requests.create!(requested_by_worker_id: "worker-1", path: "stray.log", reason: "leftover", status: "requested")
    committer = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "committer", nickname: "committer-1", reason: "test",
      scope: "commit-#{run.worktree_name}.md", status: "running", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/committer-1.prompt").to_s,
      log_path: Rails.root.join("tmp/committer-1.log").to_s,
      last_message_path: Rails.root.join("tmp/committer-1.last").to_s,
      env_path: Rails.root.join("tmp/committer-1.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: committer.worker_id })

    expect(response.structured_content[:requests].map { |entry| entry[:path] }).to eq([ "stray.log" ])
  end

  it "rejects a non-committer caller" do
    root = Dir.mktmpdir("list-git-change-requests-denied")
    workspace = Workspace.create!(name: "list-git-change-requests-denied-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "list-git-change-requests-denied-#{SecureRandom.hex(4)}", task: "Reject non-committer",
      target_root: root, launcher_variant: "claude", status: "running",
      worktree_name: "denied-a1b2", branch_name: "workflow/denied-a1b2"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-1", reason: "test",
      scope: "artifact.md", status: "running", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/worker-1.prompt").to_s,
      log_path: Rails.root.join("tmp/worker-1.log").to_s,
      last_message_path: Rails.root.join("tmp/worker-1.last").to_s,
      env_path: Rails.root.join("tmp/worker-1.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })

    expect(response.error?).to be(true)
  end
end
