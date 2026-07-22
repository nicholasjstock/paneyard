require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  it "records no_changes during the committer step without invoking GitHub" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-#{SecureRandom.hex(4)}", task: "Publish nothing", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "publish-nothing-a1b2",
      branch_name: "workflow/publish-nothing-a1b2"
    )
    allow(described_class).to receive(:git!).with(Pathname(root), "status", "--porcelain").and_return("")
    expect(described_class).not_to receive(:create_pr)

    expect(described_class.commit_all!(run)).to eq(:no_changes)
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
end
