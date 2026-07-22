require "rails_helper"

RSpec.describe Workspace do
  it "derives the source checkout from the workspace root" do
    workspace = Workspace.new(root_path: "/Users/stockn/Source/example")

    expect(workspace.source_root).to eq("/Users/stockn/Source/example/main")
  end

  it "is not initialized until it has declared protected path patterns" do
    workspace = Workspace.create!(name: "workspace-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)

    expect(workspace.initialized?).to be(false)

    workspace.update!(protected_path_patterns: [ "." ])

    expect(workspace.initialized?).to be(true)
  end

  it "resolves the complete source worktree as a protected write root" do
    project_root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(project_root, "main"))
    workspace = Workspace.create!(name: "workspace-roots-#{SecureRandom.hex(4)}", root_path: project_root, protected_path_patterns: [ "." ])

    expect(workspace.protected_write_roots).to eq([ "." ])
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
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
end
