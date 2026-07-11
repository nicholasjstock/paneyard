require "rails_helper"

RSpec.describe "workspace workers", type: :system do
  it "lists only workers for the selected workspace" do
    workspace, run = create_workspace_with_run("alpha")
    create_worker(run:, nickname: "planner-alpha", pid: 111_111)

    other_workspace, other_run = create_workspace_with_run("beta")
    create_worker(run: other_run, nickname: "planner-beta", pid: 222_222)

    visit workspace_workers_path(workspace)

    expect(page).to have_text("planner-alpha")
    expect(page).to have_no_text("planner-beta")
  end

  it "shows a worker detail page with the latest message and log content" do
    workspace, run = create_workspace_with_run("alpha")
    worker = create_worker(run:, nickname: "planner-alpha", pid: 111_111)
    File.write(worker.last_message_path, "latest update\n")
    File.write(worker.log_path, "first line\nsecond line\n")

    visit workspace_worker_path(workspace, worker.worker_id)

    expect(page).to have_text(worker.worker_id)
    expect(page).to have_text("latest update")
    expect(page).to have_text("second line")
  end

  it "stops a running worker from the workers index" do
    workspace, run = create_workspace_with_run("alpha")
    worker = create_worker(run:, nickname: "planner-alpha", pid: 999_999)

    visit workspace_workers_path(workspace)
    click_button "Stop worker"

    expect(page).to have_text("Worker stopped.")
    expect(worker.reload.status).to eq("stopped")
    expect(worker.stopped_at).to be_present
  end

  it "shows the empty state when a workspace has no workers" do
    workspace, = create_workspace_with_run("alpha")

    visit workspace_workers_path(workspace)

    expect(page).to have_text("No workers recorded.")
  end

  it "updates the worker index live when a worker is created", :js do
    workspace, run = create_workspace_with_run("alpha")

    visit workspace_workers_path(workspace)
    expect(page).to have_text("No workers recorded.")

    creator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        create_worker(run: run, nickname: "planner-live", pid: 333_333)
      end
    end

    expect(page).to have_text("planner-live")
    expect(page).to have_text(run.run_id)

    creator.join
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
