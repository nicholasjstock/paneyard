require "rails_helper"

RSpec.describe StopRunJob do
  it "stops active run commands, not just workers, so nothing keeps squatting ports after a run stops" do
    run = create_run
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "sleep", arguments: [ "30" ]
    )

    StopRunJob.perform_now(run.id)

    expect(command.reload.status).to eq("stopped")
    expect(Orchestrator::RunCommandRunner.process_alive?(command.pid)).to be(false)
    expect(run.reload.status).to eq("stopped")
  end

  it "still stops the run when stopping a run command raises" do
    run = create_run
    Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: "worker-1", executable: "sleep", arguments: [ "30" ]
    )
    allow(Orchestrator::RunCommandRunner).to receive(:stop_all_for_run).and_raise("boom")

    StopRunJob.perform_now(run.id)

    expect(run.reload.status).to eq("stopped")
  end

  def create_run
    root = Dir.mktmpdir("stop-run-job")
    workspace = Workspace.create!(name: "stop-run-job-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "stop-run-job-#{SecureRandom.hex(4)}", task: "Exercise StopRunJob",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
