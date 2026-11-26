require "rails_helper"

RSpec.describe Orchestrator::RunRunner do
  let(:workspace) { create_workspace(prefix: "run-runner") }

  def remote_runner(name, **attributes)
    RegisteredRunner.create!(name:, kind: "remote", url: "http://#{name}.tailnet:3100", **attributes)
  end

  def check_out(workspace, runner)
    workspace.checkouts.create!(runner:, repository_path: "/Users/me/code/#{workspace.name}")
  end

  it "is the local runner when it is the only one" do
    expect(described_class.choose!(workspace, nil)).to eq(RegisteredRunner.local)
    expect(described_class.candidates(workspace)).to eq([ RegisteredRunner.local ])
  end

  it "is the local runner when the workspace is checked out on several and nothing says otherwise" do
    check_out(workspace, remote_runner("laptop"))

    expect(described_class.choose!(workspace, nil)).to eq(RegisteredRunner.local)
  end

  it "is the calling run's own runner when it has a checkout of the workspace" do
    laptop = remote_runner("laptop")
    check_out(workspace, laptop)
    caller_run = create_run(workspace:, runner: laptop)

    expect(described_class.choose!(workspace, nil, caller_run:)).to eq(laptop)
  end

  it "falls back past the calling run's runner when it has no checkout of the workspace" do
    laptop = remote_runner("laptop")
    elsewhere = create_workspace(prefix: "run-runner-elsewhere")
    check_out(elsewhere, laptop)
    caller_run = create_run(workspace: elsewhere, runner: laptop)

    expect(described_class.choose!(workspace, nil, caller_run:)).to eq(RegisteredRunner.local)
  end

  it "is the runner the caller names, checked out there" do
    laptop = remote_runner("laptop")
    check_out(workspace, laptop)

    expect(described_class.choose!(workspace, "laptop")).to eq(laptop)
    expect(described_class.choose!(workspace, " local ")).to eq(RegisteredRunner.local)
    expect(described_class.candidates(workspace)).to eq([ RegisteredRunner.local, laptop ])
  end

  it "refuses a runner that does not exist, listing the valid ones" do
    check_out(workspace, remote_runner("laptop"))

    expect { described_class.choose!(workspace, "desktop") }
      .to raise_error(described_class::Invalid, /no runner named "desktop".*local, laptop/)
  end

  it "refuses a runner with no checkout of the workspace, listing the valid ones" do
    remote_runner("laptop")

    expect { described_class.choose!(workspace, "laptop") }
      .to raise_error(described_class::Invalid, /"laptop" has no checkout of workspace .*: local\./)
  end
end
