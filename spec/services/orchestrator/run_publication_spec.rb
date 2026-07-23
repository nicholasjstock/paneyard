require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  it "commits source changes but keeps runtime artifacts and the PR summary out of Git" do
    root = Dir.mktmpdir
    git(root, "init")
    git(root, "config", "user.name", "Workflow Orchestrator")
    git(root, "config", "user.email", "workflow@example.test")
    File.write(File.join(root, "existing.txt"), "before\n")
    git(root, "add", "existing.txt")
    git(root, "commit", "-m", "Initial commit")
    workspace = Workspace.create!(name: "publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-#{SecureRandom.hex(4)}", task: "Publish nothing", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "publish-nothing-a1b2",
      branch_name: "workflow/publish-nothing-a1b2"
    )
    File.write(File.join(root, "existing.txt"), "after\n")
    Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "## Result\n\nSource change verified.")
    Orchestrator::ArtifactStore.write(root, run.run_id, "worker.log", "sensitive runtime output")

    expect(described_class.commit_all!(run)).to eq(:committed)
    expect(git(root, "show", "--format=", "--name-only", "HEAD")).to include("existing.txt")
    expect(git(root, "ls-files")).not_to include(".workflow-orchestrator")
    expect(git(root, "status", "--porcelain")).to include(".workflow-orchestrator/")
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

  def git(root, *args)
    output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output
  end
end
