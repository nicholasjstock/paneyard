require "rails_helper"

RSpec.describe Workspace do
  it "is a repository and the branch its runs start from" do
    workspace = Workspace.new(name: "example", repository_path: "/home/me/src/example", default_base_branch: "develop")

    expect(workspace).to be_valid
  end

  it "refuses a default base branch git would not take, or that could pass for a flag" do
    %w[-x a..b feature/ has\ space].each do |branch|
      workspace = Workspace.new(name: "bad-#{SecureRandom.hex(2)}", repository_path: "/tmp/bad-#{SecureRandom.hex(4)}", default_base_branch: branch)

      expect(workspace).not_to be_valid, branch
    end
  end

  it "does not let an active run's repository move" do
    workspace = Workspace.create!(name: "workspace-active-#{SecureRandom.hex(4)}", repository_path: Dir.mktmpdir)
    workspace.runs.create!(
      run_id: "workspace-active-#{SecureRandom.hex(4)}", task: "Active task", target_root: workspace.repository_path,
      launcher_variant: "codex", status: "running"
    )

    expect(workspace.update(repository_path: Dir.mktmpdir)).to be(false)
    expect(workspace.errors[:repository_path]).to include("cannot change while a run is active")
  end

  describe "layout" do
    let(:workspace) { Workspace.create!(name: "workspace-layout-#{SecureRandom.hex(4)}", repository_path: Dir.mktmpdir) }

    it "accepts a valid layout and stores a blank one as the default (nil)" do
      expect(workspace.update(layout: "tabs:\n  - panes: [agent]\n")).to be(true)
      expect(workspace.update(layout: "  \n")).to be(true)
      expect(workspace.reload.layout).to be_nil
    end

    it "stores the editor's JSON as canonical YAML" do
      workspace.update!(layout: '{"tabs":[{"name":"main","panes":["agent"]}]}')

      expect(workspace.reload.layout).to eq("tabs:\n- name: main\n  panes:\n  - agent\n")
    end

    it "refuses an invalid layout with a readable error" do
      expect(workspace.update(layout: "tabs:\n  - panes: [{ name: logs }]\n")).to be(false)
      expect(workspace.errors[:layout]).to include("`agent` must be the first pane of the first tab")
    end
  end

  describe "checkouts" do
    it "records its repository as its checkout on the local runner, and keeps it there" do
      workspace = create_workspace
      checkout = workspace.checkouts.sole

      expect(checkout).to have_attributes(runner: RegisteredRunner.local, repository_path: workspace.repository_path)

      moved = Dir.mktmpdir("moved")
      workspace.update!(repository_path: moved)

      expect(checkout.reload.repository_path).to eq(moved)
      expect(workspace.checkouts.count).to eq(1)
    end

    it "resolves the repository path per runner" do
      workspace = create_workspace
      mac = RegisteredRunner.create!(name: "mac", kind: "remote", url: "http://mac.tailnet:3100")

      expect(workspace.repository_path_for(RegisteredRunner.local)).to eq(workspace.repository_path)
      expect(workspace.repository_path_for(nil)).to eq(workspace.repository_path)
      expect { workspace.repository_path_for(mac) }.to raise_error(Orchestrator::Runner::Error, /no checkout on runner "mac"/)

      workspace.checkouts.create!(runner: mac, repository_path: "/Users/me/src/app")

      expect(workspace.repository_path_for(mac)).to eq("/Users/me/src/app")
    end

    it "goes with the workspace" do
      workspace = create_workspace
      workspace.destroy!

      expect(WorkspaceCheckout.count).to eq(0)
    end
  end
end
