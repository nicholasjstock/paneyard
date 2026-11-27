require "rails_helper"

RSpec.describe Orchestrator::GitWorktree do
  it "uses a readable task slug plus the run suffix" do
    run = Run.new(task: "Add worktree support!", run_id: "run-20260722-120000-a1b2")

    expect(described_class.name_for(run)).to eq("add-worktree-support-a1b2")
  end

  it "clones the workspace on a runner with no checkout before provisioning there, and records it", :fake_herdr do
    origin = create_source_checkout(name: "origin")
    mac = RegisteredRunner.create!(name: "mac", kind: "remote", url: "http://mac.tailnet.test:3100")
    workspace = Workspace.new(name: "cloned-here", origin_url: origin)
    workspace.record_checkout(mac, "/Users/me/cloned-here")
    workspace.save!
    clone = File.join(ENV.fetch("PANEYARD_PROJECTS_DIR"), "cloned-here")
    run, session = create_run_and_session(run: create_run(workspace:, runner: RegisteredRunner.local, target_root: clone,
      worktree_name: "clone-me-a1b2", status: "launching"))

    described_class.provision!(run, session:)

    expect(workspace.reload.repository_path).to eq(clone)
    expect(fake_herdr.requests_for("worktree.create").sole).to include("cwd" => clone, "base" => "main")
    expect(run.reload).to have_attributes(source_root: clone, branch_name: "paneyard/clone-me-a1b2")
  ensure
    FileUtils.rm_rf(clone) if clone
  end

  it "fails the launch with why when the clone fails, before anything is provisioned", :fake_herdr do
    mac = RegisteredRunner.create!(name: "mac", kind: "remote", url: "http://mac.tailnet.test:3100")
    workspace = Workspace.new(name: "no-access", origin_url: File.join(Dir.mktmpdir("no-access"), "missing.git"))
    workspace.record_checkout(mac, "/Users/me/no-access")
    workspace.save!
    run, = create_run_and_session(run: create_run(workspace:, runner: RegisteredRunner.local, target_root: "/planned",
      worktree_name: "no-access-a1b2", status: "launching"))
    run.run_sessions.delete_all

    expect { StartRunSessionJob.perform_now(run.id) }.to raise_error(Orchestrator::WorkspaceCheckout::Unavailable)

    expect(run.reload).to have_attributes(status: "failed", launch_error: include("Could not check workspace \"no-access\" out on runner local", "git clone"))
    expect(fake_herdr.requests_for("worktree.create")).to be_empty
    expect(workspace.checkouts.reload.map(&:runner)).to eq([ mac ])
    # Reopening it tries the clone again at launch.
    expect(Orchestrator::SessionReopen.problem(run)).to be_nil
  end

  it "does not mistake the repository for a provisioned worktree to reopen", :fake_herdr do
    repository = create_source_checkout
    workspace = create_workspace(repository_path: repository)
    run, session = create_run_and_session(run: create_run(
      workspace:, target_root: repository, worktree_name: "add-todo-a1b2", branch_name: "paneyard/add-todo-a1b2",
      source_root: repository, status: "launching"
    ))

    described_class.provision!(run, session:)

    expect(fake_herdr.requests_for("worktree.open")).to be_empty
    expect(fake_herdr.requests_for("worktree.create").sole).to include("branch" => "paneyard/add-todo-a1b2")
    expect(run.reload.target_root).not_to eq(repository)
  end

  it "has herdr make the worktree from local base HEAD, leaving the operator's checkout and its uncommitted work alone", :fake_herdr do
    repository = create_source_checkout
    system("git", "-C", repository, "commit", "-q", "--allow-empty", "-m", "Local only", exception: true)
    local_head = `git -C #{Shellwords.escape(repository)} rev-parse HEAD`.strip
    File.write(File.join(repository, "operator-draft.txt"), "uncommitted in the operator's checkout\n")
    workspace = create_workspace(repository_path: repository)
    run, session = create_run_and_session(run: workspace.runs.create!(
      run_id: "run-20260722-120000-a1b2", task: "Add local file", target_root: repository,
      launcher_variant: "codex", status: "launching", worktree_name: "add-local-file-a1b2"
    ))

    described_class.provision!(run, session:)

    expect(run.reload).to have_attributes(base_sha: local_head, base_branch: "main", source_root: repository,
      branch_name: "paneyard/add-local-file-a1b2")
    expect(session.reload).to have_attributes(herdr_workspace_id: "w1", herdr_tab_id: "w1:t1", herdr_pane_id: "w1:p1")
    expect(File).not_to exist(File.join(run.target_root, "operator-draft.txt"))
    expect(File).to exist(File.join(repository, "operator-draft.txt"))
  end

  it "reopens the run's own worktree on a retried launch instead of making another", :fake_herdr do
    workspace = create_workspace(repository_path: create_source_checkout)
    run, session = create_run_and_session(run: create_run(workspace:, status: "launching", worktree_name: "retry-a1b2"))
    described_class.provision!(run, session:)
    first = run.reload.target_root
    fake_herdr.close_workspace!("w1")

    described_class.provision!(run, session:)

    expect(run.reload.target_root).to eq(first)
    expect(fake_herdr.requests_for("worktree.create").size).to eq(1)
    expect(fake_herdr.requests_for("worktree.open").sole).to include("path" => first)
  end

  # A reopened run whose worktree was removed (SessionReopen).
  it "makes the worktree again on the run's existing branch, keeping its commits and its base", :fake_herdr do
    repository = create_source_checkout
    workspace = create_workspace(repository_path: repository)
    run, session = create_run_and_session(run: create_run(workspace:, status: "launching", worktree_name: "again-a1b2"))
    described_class.provision!(run, session:)
    first = run.reload.target_root
    base_sha = run.base_sha
    system("git", "-C", first, "-c", "user.email=a@example.test", "-c", "user.name=A", "commit", "-q", "--allow-empty", "-m", "Work",
      exception: true)
    work = `git -C #{Shellwords.escape(first)} rev-parse HEAD`.strip
    Orchestrator::Runner.local.remove_worktree(repository_path: repository, path: first)
    # The base branch moving on, or even going, is no concern of the run's own branch.
    system("git", "-C", repository, "commit", "-q", "--allow-empty", "-m", "Later on main", exception: true)

    described_class.provision!(run, session:)

    expect(run.reload).to have_attributes(target_root: first, base_sha:, branch_name: "paneyard/again-a1b2")
    expect(`git -C #{Shellwords.escape(first)} rev-parse HEAD`.strip).to eq(work)
    expect(fake_herdr.requests_for("worktree.create").last).to include("branch" => "paneyard/again-a1b2", "base" => nil)
  end
end
