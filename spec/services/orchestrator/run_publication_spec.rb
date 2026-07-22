require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  it "records no_changes without invoking GitHub" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-#{SecureRandom.hex(4)}", task: "Publish nothing", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "publish-nothing-a1b2",
      branch_name: "workflow/publish-nothing-a1b2"
    )
    allow(described_class).to receive(:git!).with(Pathname(root), "status", "--porcelain").and_return("")
    expect(described_class).not_to receive(:create_pr)

    expect(described_class.publish!(run)).to eq(:no_changes)
    expect(run.reload.publication_status).to eq("no_changes")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "refuses to publish from the source checkout" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-source-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-source-#{SecureRandom.hex(4)}", task: "Do not publish source", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "source-a1b2", source_root: root,
      branch_name: "workflow/source-a1b2"
    )

    expect { described_class.publish!(run) }.to raise_error(Orchestrator::RunPublication::Error, /source checkout/)
    expect(run.reload.publication_status).to eq("failed")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end
end
