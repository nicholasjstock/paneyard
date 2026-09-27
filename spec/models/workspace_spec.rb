require "rails_helper"

RSpec.describe Workspace do
  it "derives the source checkout from the workspace root" do
    workspace = Workspace.new(root_path: "/Users/stockn/Source/example")

    expect(workspace.source_root).to eq("/Users/stockn/Source/example/main")
  end

  it "does not let an active run's source checkout move" do
    workspace = Workspace.create!(name: "workspace-active-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.runs.create!(
      run_id: "workspace-active-#{SecureRandom.hex(4)}", task: "Active task", target_root: workspace.root_path,
      launcher_variant: "codex", status: "running"
    )

    expect(workspace.update(root_path: Dir.mktmpdir)).to be(false)
    expect(workspace.errors[:root_path]).to include("cannot change while a run is active")
  end

  describe "layout" do
    let(:workspace) { Workspace.create!(name: "workspace-layout-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir) }

    it "accepts a valid layout and stores a blank one as the default (nil)" do
      expect(workspace.update(layout: "tabs:\n  - panes: [agent]\n")).to be(true)
      expect(workspace.update(layout: "  \n")).to be(true)
      expect(workspace.reload.layout).to be_nil
    end

    it "refuses an invalid layout with a readable error" do
      expect(workspace.update(layout: "tabs:\n  - panes: [{ name: logs }]\n")).to be(false)
      expect(workspace.errors[:layout]).to include("`agent` must be the first pane of the first tab")
    end
  end
end
