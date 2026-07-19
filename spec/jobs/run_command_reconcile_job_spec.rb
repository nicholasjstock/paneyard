require "rails_helper"

RSpec.describe RunCommandReconcileJob do
  it "marks an exited process as exited and a pending row stuck past the threshold as lost" do
    run = create_run
    exited = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/echo", arguments: [ "hi" ]
    )
    Timeout.timeout(5) { sleep 0.05 until Orchestrator::RunCommandRunner.process_alive?(exited.pid) == false }

    stuck = run.run_commands.create!(
      executable: "/bin/echo", working_directory: run.target_root, status: "pending",
      created_at: 1.minute.ago, updated_at: 1.minute.ago
    )

    RunCommandReconcileJob.perform_now

    expect(exited.reload.status).to eq("exited")
    expect(exited.exit_code).to eq(0)
    expect(stuck.reload.status).to eq("lost")
  end

  it "does not republish an event for a command reconciled more than once" do
    run = create_run
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/echo", arguments: [ "hi" ]
    )
    Timeout.timeout(5) { sleep 0.05 until Orchestrator::RunCommandRunner.process_alive?(command.pid) == false }

    2.times { RunCommandReconcileJob.perform_now }

    expect(BusEvent.where(run_id: run.run_id, event_type: "command.exited").count).to eq(1)
  end

  def create_run
    root = Dir.mktmpdir("run-command-reconcile-job")
    workspace = Workspace.create!(name: "run-command-reconcile-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "run-command-reconcile-#{SecureRandom.hex(4)}", task: "Exercise RunCommandReconcileJob",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
