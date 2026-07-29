require "rails_helper"

RSpec.describe "worker detail", type: :system do
  it "shows a worker detail page with the latest message and log content" do
    workspace, run = create_workspace_with_run("alpha")
    worker = create_worker(run:, nickname: "planner-alpha", pid: 111_111)
    File.write(worker.last_message_path, "latest update\n")
    File.write(worker.log_path, "first line\nsecond line\n")

    visit workspace_worker_path(workspace, worker.worker_id)

    expect(page).to have_text(worker.worker_id)
    expect(page).to have_text("latest update")
    expect(page).to have_text("second line")
    expect(page).to have_link("Back to run", href: workspace_run_path(workspace, run))
  end

  def create_workspace_with_run(prefix)
    suffix = "#{prefix}-#{SecureRandom.hex(4)}"
    workspace = Workspace.create!(name: "planner-#{suffix}", root_path: "/tmp/planner-#{suffix}")
    run = Run.create!(
      run_id: "demo-#{suffix}",
      task: "Inspect workers in #{prefix}",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )
    FileUtils.mkdir_p(File.join(workspace.root_path, "front", "demo-output", "agents-sdk", "workers"))
    [ workspace, run ]
  end

  def create_worker(run:, nickname:, pid:)
    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "planner",
      nickname: nickname,
      reason: "Testing worker coverage.",
      scope: "workflow-plan.md",
      status: "running",
      pid: pid,
      prompt_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "#{nickname}.prompt.txt"),
      log_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "#{nickname}.log"),
      last_message_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "#{nickname}.last-message.txt"),
      env_path: File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers", "#{nickname}.env.json"),
      command: "claude",
      args: []
    )
  end
end
