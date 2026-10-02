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
end
