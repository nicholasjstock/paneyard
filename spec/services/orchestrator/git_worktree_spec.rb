require "rails_helper"

RSpec.describe Orchestrator::GitWorktree do
  it "uses a readable task slug plus the run suffix" do
    run = Run.new(task: "Add worktree support!", run_id: "run-20260722-120000-a1b2")

    expect(described_class.name_for(run)).to eq("add-worktree-support-a1b2")
  end

  it "rejects a dirty source checkout" do
    root = Pathname(Dir.mktmpdir).join("main")
    FileUtils.mkdir_p(root)
    system("git", "-C", root.to_s, "init", "--quiet", exception: true)
    File.write(root.join("dirty.txt"), "dirty")

    expect { described_class.validate_source!(root) }.to raise_error(Orchestrator::GitWorktree::Error, /uncommitted changes/)
  ensure
    FileUtils.remove_entry(root.parent) if root&.parent&.exist?
  end
end
