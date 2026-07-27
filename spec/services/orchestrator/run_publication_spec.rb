require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  describe ".queue_worker!" do
    it "spawns a git-role SpawnRequest and marks the run commit_pending" do
      workspace = Workspace.create!(name: "publication-queue-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-queue-#{SecureRandom.hex(4)}", task: "Finalize the run", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "queue-a1b2", branch_name: "workflow/queue-a1b2"
      )

      described_class.queue_worker!(run)

      expect(run.reload.publication_status).to eq("commit_pending")
      request = SpawnRequest.find_by(run_id: run.run_id, requested_role: "git")
      expect(request).to have_attributes(write_scope: "git_managed", allowed_paths: [ "**/*" ], model_tier: "small", status: "open")
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "does not spawn a second request while one is already open" do
      workspace = Workspace.create!(name: "publication-queue-dup-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-queue-dup-#{SecureRandom.hex(4)}", task: "Finalize the run", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "queue-dup-a1b2", branch_name: "workflow/queue-dup-a1b2"
      )

      described_class.queue_worker!(run)
      described_class.queue_worker!(run)

      expect(SpawnRequest.where(run_id: run.run_id, requested_role: "git").count).to eq(1)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end
  end

  describe ".finalize!" do
    it "persists a published outcome, applies review asset URLs, and opens the reviewer question" do
      workspace = Workspace.create!(name: "publication-finalize-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-finalize-#{SecureRandom.hex(4)}", task: "Finalize the run", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "finalize-a1b2", branch_name: "workflow/finalize-a1b2"
      )
      asset = run.review_assets.create!(workspace_path: "screenshot.png", label: "Screenshot")

      outcome = described_class.finalize!(
        run, outcome: "published", pull_request_url: "https://github.com/example/repo/pull/42",
        review_assets: [ { workspacePath: "screenshot.png", githubUrl: "https://github.com/example/repo/releases/download/x/screenshot.png" } ]
      )

      expect(outcome).to eq(:published)
      expect(run.reload).to have_attributes(
        publication_status: "awaiting_approval", pull_request_url: "https://github.com/example/repo/pull/42",
        conversation_pr_status: "ready", status: "completed"
      )
      expect(asset.reload.github_url).to eq("https://github.com/example/repo/releases/download/x/screenshot.png")
      expect(run.open_blocking_question?).to be(true)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "persists a no_changes outcome as completed without opening a review question" do
      workspace = Workspace.create!(name: "publication-nochange-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-nochange-#{SecureRandom.hex(4)}", task: "Nothing to publish", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "nochange-a1b2", branch_name: "workflow/nochange-a1b2"
      )

      expect(described_class.finalize!(run, outcome: "no_changes")).to eq(:no_changes)
      expect(run.reload).to have_attributes(publication_status: "no_changes", status: "completed")
      expect(run.open_blocking_question?).to be(false)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "persists a failed outcome with the reported error" do
      workspace = Workspace.create!(name: "publication-failed-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-failed-#{SecureRandom.hex(4)}", task: "Fails to publish", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "failed-a1b2", branch_name: "workflow/failed-a1b2"
      )

      expect(described_class.finalize!(run, outcome: "failed", error: "push rejected")).to eq(:failed)
      expect(run.reload).to have_attributes(publication_status: "failed", publication_error: "push rejected", status: "failed")
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "rejects an unknown outcome" do
      workspace = Workspace.create!(name: "publication-unknown-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-unknown-#{SecureRandom.hex(4)}", task: "Bad outcome", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "unknown-a1b2", branch_name: "workflow/unknown-a1b2"
      )

      expect { described_class.finalize!(run, outcome: "bogus") }.to raise_error(Orchestrator::RunPublication::Error, /Unknown publication outcome/)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end
  end

  it "posts each question as a marked PR comment" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "question-publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "question-publication-#{SecureRandom.hex(4)}", task: "Ask on GitHub", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "question-publication-a1b2",
      branch_name: "workflow/question-publication-a1b2"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Choose a setting?", priority: "blocking")
    allow(described_class).to receive(:ensure_conversation_pr!).and_return("https://github.com/example/repo/pull/42")
    allow(described_class).to receive(:validated_root!).and_return(Pathname(root))
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 123, html_url: "https://github.com/example/repo/pull/42#issuecomment-123" }.to_json, "", status ])

    expect(described_class.publish_question!(question)).to eq(:published)
    expect(question.reload).to have_attributes(
      github_comment_id: "123", github_comment_url: "https://github.com/example/repo/pull/42#issuecomment-123"
    )
    expect(Open3).to have_received(:capture3).with(*a_string_starting_with("gh"), any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "states that no review evidence was uploaded without listing local artifacts" do
    section = described_class.send(:review_assets_section, [])

    expect(section).to eq("## Review evidence\n\nNo review assets were selected for upload.")
    expect(section).not_to include("run-summary.md")
  end

  it "does not let a missing historical worktree raise during merge detection" do
    workspace = Workspace.create!(name: "publication-missing-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "publication-missing-#{SecureRandom.hex(4)}", task: "Skip missing worktree",
      target_root: File.join(workspace.root_path, "missing"), launcher_variant: "codex", worktree_name: "missing-a1b2",
      branch_name: "workflow/missing-a1b2", pull_request_url: "https://github.com/example/repo/pull/42"
    )

    expect(described_class.merged?(run)).to be(false)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "removes the exact run worktree after GitHub has merged the PR" do
    source_root = Dir.mktmpdir
    worktree_root = Dir.mktmpdir
    FileUtils.remove_entry(worktree_root)
    git(source_root, "init")
    git(source_root, "config", "user.name", "Workflow Orchestrator")
    git(source_root, "config", "user.email", "workflow@example.test")
    File.write(File.join(source_root, "README.md"), "source\n")
    git(source_root, "add", "README.md")
    git(source_root, "commit", "-m", "Initial commit")
    git(source_root, "branch", "-M", "main")
    git(source_root, "remote", "add", "origin", source_root)
    git(source_root, "worktree", "add", "-b", "workflow/merged-a1b2", worktree_root)
    workspace = Workspace.create!(name: "publication-cleanup-#{SecureRandom.hex(4)}", root_path: source_root)
    run = workspace.runs.create!(
      run_id: "publication-cleanup-#{SecureRandom.hex(4)}", task: "Clean merged run",
      target_root: worktree_root, source_root:, launcher_variant: "codex", worktree_name: "merged-a1b2",
      branch_name: "workflow/merged-a1b2", publication_status: "awaiting_approval"
    )

    expect(described_class.cleanup_merged_run!(run)).to eq(:merged)
    expect(File).not_to exist(worktree_root)
    expect(run.reload.publication_status).to eq("merged")
  ensure
    FileUtils.remove_entry(source_root) if source_root && File.exist?(source_root)
  end

  def git(root, *args)
    output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output
  end
end
