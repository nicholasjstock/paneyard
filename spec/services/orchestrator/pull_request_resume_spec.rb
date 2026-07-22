require "rails_helper"

RSpec.describe Orchestrator::PullRequestResume do
  before { Run.reset_column_information }

  it "records every PR comment and queues a continuation planner request" do
    workspace = Workspace.create!(name: "pr-resume-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-resume-#{SecureRandom.hex(4)}", task: "Resume from PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "resume-a1b2", branch_name: "workflow/resume-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    comment = { "id" => 123, "body" => "Please add a test.", "user" => { "login" => "reviewer" } }

    described_class.resume!(run, comment)

    expect(run.reload).to have_attributes(status: "running", publication_status: "resume_requested", last_pull_request_comment_id: "123")
    expect(run.run_context_entries.find_by!(entry_key: "pr-comment-123").content).to include("Please add a test.")
    expect(run.spawn_requests.find_by!(asked_by: "github_pr_comment").context).to include("Please add a test.")
  end

  it "does not reprocess an already-recorded comment" do
    workspace = Workspace.create!(name: "pr-resume-repeat-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-resume-repeat-#{SecureRandom.hex(4)}", task: "Resume from PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "resume-repeat-a1b2", branch_name: "workflow/resume-repeat-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval", last_pull_request_comment_id: "123"
    )

    expect { described_class.resume!(run, { "id" => 123, "body" => "Again", "user" => { "login" => "reviewer" } }) }
      .not_to change(SpawnRequest, :count)
  end

  it "answers only explicitly referenced questions while resuming the run" do
    workspace = Workspace.create!(name: "pr-question-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-question-#{SecureRandom.hex(4)}", task: "Answer from PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "question-a1b2", branch_name: "workflow/question-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Use the new setting?", priority: "blocking")
    other_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Keep this open?", priority: "blocking")

    described_class.resume!(run, { "id" => 124, "body" => "Question #{question.question_id}: yes, use it", "user" => { "login" => "reviewer" } })

    expect(question.reload).to have_attributes(status: "answered", answered_by: "github:reviewer", answer_text: "yes, use it")
    expect(other_question.reload.status).to eq("open")
    expect(run.reload.status).to eq("running")
  end

  it "ignores system-posted question comments while advancing the cursor" do
    workspace = Workspace.create!(name: "pr-system-question-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-system-question-#{SecureRandom.hex(4)}", task: "Ignore system comment", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "system-question-a1b2", branch_name: "workflow/system-question-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Question", github_comment_id: "125")

    expect { described_class.resume!(run, { "id" => 125, "body" => "System question", "user" => { "login" => "bot" } }) }
      .not_to change(SpawnRequest, :count)
    expect(run.reload.last_pull_request_comment_id).to eq("125")
  end
end
