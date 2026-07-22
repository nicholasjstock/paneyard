require "rails_helper"

RSpec.describe Orchestrator::GitWorktree do
  it "uses a readable task slug plus the run suffix" do
    run = Run.new(task: "Add worktree support!", run_id: "run-20260722-120000-a1b2")

    expect(described_class.name_for(run)).to eq("add-worktree-support-a1b2")
  end

  it "does not mistake the source checkout for a provisioned worktree" do
    root = Pathname(Dir.mktmpdir).join("main")
    FileUtils.mkdir_p(root)
    run = Run.new(
      target_root: root.to_s, worktree_name: "add-todo-a1b2", branch_name: "workflow/add-todo-a1b2",
      source_root: root.to_s
    )

    expect(described_class.provisioned?(run, root.parent.join("add-todo-a1b2"))).to be(false)
  ensure
    FileUtils.remove_entry(root.parent) if root&.parent&.exist?
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

  it "creates the run worktree from local main HEAD, not origin/main" do
    project_root = Pathname(Dir.mktmpdir)
    source_root = project_root.join("main")
    remote_root = project_root.join("origin.git")
    FileUtils.mkdir_p(source_root)
    command!("git", "init", "--initial-branch=main", source_root.to_s)
    command!("git", "-C", source_root.to_s, "config", "user.email", "test@example.com")
    command!("git", "-C", source_root.to_s, "config", "user.name", "Test User")
    File.write(source_root.join("base.txt"), "base\n")
    command!("git", "-C", source_root.to_s, "add", "base.txt")
    command!("git", "-C", source_root.to_s, "commit", "-m", "Base")
    command!("git", "init", "--bare", remote_root.to_s)
    command!("git", "-C", source_root.to_s, "remote", "add", "origin", remote_root.to_s)
    command!("git", "-C", source_root.to_s, "push", "-u", "origin", "main")
    File.write(source_root.join("local-only.txt"), "local\n")
    command!("git", "-C", source_root.to_s, "add", "local-only.txt")
    command!("git", "-C", source_root.to_s, "commit", "-m", "Local only")
    local_head = `git -C #{Shellwords.escape(source_root.to_s)} rev-parse HEAD`.strip

    workspace = Workspace.create!(name: "git-worktree-#{SecureRandom.hex(4)}", root_path: project_root.to_s)
    run = workspace.runs.create!(
      run_id: "run-20260722-120000-a1b2", task: "Add local file", target_root: workspace.source_root,
      launcher_variant: "codex", status: "launching", worktree_name: "add-local-file-a1b2"
    )

    described_class.provision!(run)

    expect(run.reload.base_sha).to eq(local_head)
    expect(File).to exist(File.join(run.target_root, "local-only.txt"))
  ensure
    FileUtils.remove_entry(project_root) if project_root&.exist?
  end

  def command!(*command)
    system(*command, exception: true)
  end
end
