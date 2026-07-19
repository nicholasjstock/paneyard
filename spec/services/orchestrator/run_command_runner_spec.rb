require "rails_helper"

RSpec.describe Orchestrator::RunCommandRunner do
  it "persists a pending record before spawning, and marks it failed if spawn raises" do
    run = create_run
    allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, "no such file")

    command = described_class.start(run: run, requested_by_worker_id: "worker-1", executable: "/bin/definitely-missing")

    expect(command).to be_persisted
    expect(command.status).to eq("failed")
    expect(command.failure_message).to be_present
  end

  it "starts a real process, redirects stdout/stderr to the log, and survives without any worker process" do
    run = create_run

    command = described_class.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/echo", arguments: [ "hello-run-command" ],
      purpose: "smoke test"
    )

    expect(command.status).to eq("running")
    expect(command.pid).to be_present
    expect(command.process_group_id).to eq(command.pid)

    wait_until { described_class.reconcile!(command.reload).status == "exited" }

    expect(command.reload.exit_code).to eq(0)
    expect(File.read(command.log_path)).to include("hello-run-command")
  end

  it "marks a process lost when it disappears without a recoverable exit status" do
    run = create_run
    command = described_class.start(run: run, requested_by_worker_id: "worker-1", executable: "/bin/sleep", arguments: [ "5" ])
    File.delete(command.exit_status_path) if File.exist?(command.exit_status_path)
    Process.kill("KILL", command.pid)

    wait_until { described_class.reconcile!(command.reload).terminal? }

    expect(command.reload.status).to eq("lost")
  end

  it "read_log_window respects offset/limit and clamps to the max read size" do
    run = create_run
    command = run.run_commands.create!(executable: "/bin/echo", working_directory: run.target_root)
    log_path = File.join(Dir.mktmpdir("run-command-log"), "cmd.log")
    File.write(log_path, "0123456789")
    command.update!(log_path: log_path)

    window = described_class.read_log_window(command, offset: 2, limit: 3)
    expect(window[:text]).to eq("234")
    expect(window[:cursor]).to eq(2)
    expect(window[:next_cursor]).to eq(5)
    expect(window[:has_more]).to be(true)

    clamped = described_class.read_log_window(command, offset: 0, limit: described_class::MAX_LOG_READ_LIMIT + 1_000)
    expect(clamped[:text].bytesize).to be <= described_class::MAX_LOG_READ_LIMIT
  end

  it "read_log_window does not raise on an empty log file" do
    run = create_run
    log_path = File.join(Dir.mktmpdir("run-command-empty-log"), "cmd.log")
    File.write(log_path, "")
    command = run.run_commands.create!(executable: "/bin/echo", working_directory: run.target_root, log_path: log_path)

    window = described_class.read_log_window(command, offset: 0, limit: 100)

    expect(window[:text]).to eq("")
    expect(window[:has_more]).to be(false)
  end

  it "stops a running process by signaling its process group, and is idempotent" do
    run = create_run
    command = described_class.start(
      run: run, requested_by_worker_id: "worker-1", executable: "/bin/sleep", arguments: [ "30" ]
    )
    pid = command.pid

    stopped = described_class.stop(command: command, reason: "test cleanup")

    expect(stopped.status).to eq("stopped")
    expect(process_alive?(pid)).to be(false)

    again = described_class.stop(command: command, reason: "second call")
    expect(again.status).to eq("stopped")
    expect(BusEvent.where(run_id: run.run_id, event_type: "command.stopped").count).to eq(1)
  end

  it "rejects a working directory that escapes the run's target_root" do
    run = create_run

    expect {
      described_class.start(run: run, requested_by_worker_id: "worker-1", executable: "/bin/echo", working_directory: "../../etc")
    }.to raise_error(ArgumentError)
  end

  def create_run
    root = Dir.mktmpdir("run-command-runner")
    workspace = Workspace.create!(name: "run-command-runner-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "run-command-runner-#{SecureRandom.hex(4)}", task: "Exercise RunCommandRunner",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      raise "condition not met within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end
end
