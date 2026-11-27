require "rails_helper"
require "open3"

# A runner's checkout of a workspace, cloned when it has none. The local
# runner here clones for real (into a temporary projects directory); a remote
# one is a second Runner::Local in this process, as in run_move_spec.
RSpec.describe Orchestrator::WorkspaceCheckout do
  let(:tmp) { File.realpath(Dir.mktmpdir("workspace-checkout")) }
  let(:projects) { File.join(tmp, "Source") }
  let(:origin) { create_source_checkout(name: "origin") }
  let!(:mac) { RegisteredRunner.create!(name: "mac", kind: "remote", url: "http://mac.tailnet.test:3100") }
  let(:on_mac) { Orchestrator::Runner::Local.new(runtime_root: File.join(tmp, "mac")) }

  around do |example|
    saved = ENV["PANEYARD_PROJECTS_DIR"]
    ENV["PANEYARD_PROJECTS_DIR"] = projects
    example.run
  ensure
    ENV["PANEYARD_PROJECTS_DIR"] = saved
    FileUtils.remove_entry(tmp) if File.exist?(tmp)
  end

  before do
    allow(Orchestrator::Runner).to receive(:resolve).and_wrap_original do |original, record|
      record&.name == "mac" ? on_mac : original.call(record)
    end
  end

  # Registered on mac only, as register_workspace with runner: "mac" leaves it.
  def remote_only(origin_url: origin, name: "app")
    workspace = Workspace.new(name:, origin_url:)
    workspace.record_checkout(mac, origin)
    workspace.save!
    workspace
  end

  it "hands back a checkout a runner already has, without asking it anything" do
    workspace = create_workspace
    allow(Orchestrator::Runner.for(nil)).to receive(:ensure_checkout)

    expect(described_class.ensure!(workspace, nil)).to eq(workspace.repository_path)
    expect(Orchestrator::Runner.for(nil)).not_to have_received(:ensure_checkout)
  end

  it "clones the origin into the runner's projects directory as the workspace's name, and records it" do
    workspace = remote_only

    path = described_class.ensure!(workspace, RegisteredRunner.local)

    expect(path).to eq(File.join(projects, "app"))
    expect(File.read(File.join(path, "README.md"))).to eq("source checkout fixture\n")
    expect(workspace.reload.repository_path).to eq(path)
    expect(workspace.repository_path_for(nil)).to eq(path)
    expect(workspace.checkouts.count).to eq(2)
    # Again: the recorded checkout, no second clone.
    expect(described_class.ensure!(workspace, RegisteredRunner.local)).to eq(path)
  end

  it "reads the origin from a checkout another runner has, and keeps it, when the workspace has none stored" do
    workspace = remote_only(origin_url: nil)
    expect(workspace.origin_url).to be_nil
    allow(on_mac).to receive(:origin_url).and_return(origin)

    described_class.ensure!(workspace, RegisteredRunner.local)

    expect(on_mac).to have_received(:origin_url).with(path: origin)
    expect(workspace.reload.origin_url).to eq(origin)
  end

  it "reuses a clone of the same origin already in the projects directory" do
    workspace = remote_only
    FileUtils.mkdir_p(projects)
    system("git", "clone", "-q", origin, File.join(projects, "app"), exception: true)
    File.write(File.join(projects, "app", "mine.txt"), "mine\n")

    expect(described_class.ensure!(workspace, RegisteredRunner.local)).to eq(File.join(projects, "app"))
    expect(File.read(File.join(projects, "app", "mine.txt"))).to eq("mine\n")
  end

  it "fails with why, recording nothing, when the runner cannot get one" do
    workspace = remote_only
    FileUtils.mkdir_p(File.join(projects, "app"))
    File.write(File.join(projects, "app", "notes.txt"), "x")

    expect { described_class.ensure!(workspace, RegisteredRunner.local) }
      .to raise_error(described_class::Unavailable, /Could not check workspace "app" out on runner local: .*not a git checkout/)
    expect(workspace.checkouts.reload.map(&:runner)).to eq([ mac ])
  end

  it "fails a clone that git refuses (no access, say) with git's reason" do
    workspace = remote_only(origin_url: File.join(tmp, "missing.git"))

    expect { described_class.ensure!(workspace, RegisteredRunner.local) }
      .to raise_error(described_class::Unavailable, /git clone .* failed.*git credentials/m)
  end

  it "refuses a runner with no projects directory, and a workspace with no origin it can find" do
    nas = RegisteredRunner.create!(name: "nas", kind: "remote", url: "http://nas.tailnet.test:3100")
    workspace = remote_only

    expect(described_class.available?(workspace, nas)).to be(false)
    expect { described_class.ensure!(workspace, nas) }.to raise_error(described_class::Unavailable, /no projects directory/)

    orphan = Workspace.new(name: "orphan")
    orphan.record_checkout(mac, File.join(tmp, "elsewhere"))
    orphan.save!
    allow(on_mac).to receive(:origin_url).and_raise(Orchestrator::Runner::Error, "no origin")
    expect { described_class.ensure!(orphan, RegisteredRunner.local) }.to raise_error(described_class::Unavailable, /no origin to clone/)
  end

  it "plans the clone where the runner keeps projects" do
    nas = RegisteredRunner.create!(name: "nas", kind: "remote", url: "http://nas.tailnet.test:3100", projects_dir: "/volume1/src/")
    workspace = remote_only

    expect(described_class.planned_path(workspace, nas)).to eq("/volume1/src/app")
    expect(described_class.planned_path(workspace, RegisteredRunner.local)).to eq(File.join(projects, "app"))
    expect(described_class.available?(workspace, nas)).to be(true)
  end
end
