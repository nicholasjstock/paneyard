require "rails_helper"

RSpec.describe McpTools::GetRunAuditTool do
  it "surfaces a worker's clickPath so the reporter can carry it into the PR summary" do
    root = Dir.mktmpdir("get-run-audit-click-path")
    workspace = Workspace.create!(name: "get-run-audit-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "get-run-audit-#{SecureRandom.hex(4)}", task: "Add a dropdown",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-1", reason: "Add a dropdown",
      scope: "fix-summary.md", status: "stopped", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/worker-1.prompt").to_s,
      log_path: Rails.root.join("tmp/worker-1.log").to_s,
      last_message_path: Rails.root.join("tmp/worker-1.last").to_s,
      env_path: Rails.root.join("tmp/worker-1.env").to_s,
      click_path: "Open the workspace, click the current-runs dropdown, select the long-title entry."
    )
    reporter = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter-1", reason: "Report it",
      scope: "run-summary.md", status: "running", pid: 12_346, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/reporter-1.prompt").to_s,
      log_path: Rails.root.join("tmp/reporter-1.log").to_s,
      last_message_path: Rails.root.join("tmp/reporter-1.last").to_s,
      env_path: Rails.root.join("tmp/reporter-1.env").to_s
    )

    response = described_class.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })

    worker_entry = response.structured_content[:workers].find { |entry| entry[:workerId] == worker.worker_id }
    expect(worker_entry[:clickPath]).to eq(
      "Open the workspace, click the current-runs dropdown, select the long-title entry."
    )
  end
end
