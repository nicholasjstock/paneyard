require "rails_helper"

RSpec.describe RunCommand, type: :model do
  it "assigns a command_id and defaults to pending on create" do
    run = create_run

    command = run.run_commands.create!(
      executable: "/bin/echo", working_directory: run.target_root
    )

    expect(command.command_id).to be_present
    expect(command.status).to eq("pending")
    expect(command.to_param).to eq(command.command_id)
  end

  it "publishes exactly one command.exited event across repeated identical status updates" do
    run = create_run
    command = run.run_commands.create!(
      executable: "/bin/echo", working_directory: run.target_root, status: "running", pid: 1, started_at: Time.current
    )

    command.update!(status: "exited", exit_code: 0, finished_at: Time.current)
    command.update!(exit_code: 0) # no status change -- must not republish
    command.update!(status: "exited") # same status again -- must not republish

    expect(BusEvent.where(run_id: run.run_id, event_type: "command.exited").count).to eq(1)
  end

  it "publishes distinct events for each real status transition" do
    run = create_run
    command = run.run_commands.create!(executable: "/bin/echo", working_directory: run.target_root)

    command.update!(status: "running", pid: 1, started_at: Time.current)
    command.update!(status: "exited", exit_code: 0, finished_at: Time.current)

    types = BusEvent.where(run_id: run.run_id).order(:created_at).pluck(:event_type)
    expect(types).to eq(%w[command.started command.exited])
  end

  it "redacts environment values from as_json, keeping only variable names" do
    run = create_run
    command = run.run_commands.create!(
      executable: "/bin/echo", working_directory: run.target_root, environment: { "TOKEN" => "super-secret" }
    )

    expect(command.as_json[:environment]).to eq([ "TOKEN" ])
    expect(command.as_json.to_s).not_to include("super-secret")
  end

  it "exposes active?/terminal? consistent with ACTIVE_STATUSES" do
    run = create_run
    pending = run.run_commands.create!(executable: "/bin/echo", working_directory: run.target_root)
    exited = run.run_commands.create!(
      executable: "/bin/echo", working_directory: run.target_root, status: "exited", finished_at: Time.current
    )

    expect(pending.active?).to be(true)
    expect(pending.terminal?).to be(false)
    expect(exited.active?).to be(false)
    expect(exited.terminal?).to be(true)
  end

  def create_run
    root = Dir.mktmpdir("run-command-model")
    workspace = Workspace.create!(name: "run-command-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "run-command-#{SecureRandom.hex(4)}", task: "Exercise RunCommand",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
