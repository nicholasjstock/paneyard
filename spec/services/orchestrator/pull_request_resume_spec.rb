require "rails_helper"

RSpec.describe Orchestrator::PullRequestResume do
  before { Run.reset_column_information }

  it "implicitly answers the sole open blocking question, reconciles a published run with main, and still queues a continuation planner request" do
    workspace = Workspace.create!(name: "pr-resume-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-resume-#{SecureRandom.hex(4)}", task: "Resume from PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "resume-a1b2", branch_name: "workflow/resume-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    review_question = UserQuestion.create!(
      run_id: run.run_id, asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking",
      text: "This run's work is ready for review."
    )
    comment = { "id" => 123, "body" => "Please add a test.", "user" => { "login" => "reviewer" } }

    described_class.resume!(run, comment)

    expect(run.reload).to have_attributes(status: "running", publication_status: "commit_pending", last_pull_request_comment_id: "123")
    expect(review_question.reload).to have_attributes(status: "answered", answered_by: "github:reviewer", answer_text: "Please add a test.")
    expect(run.run_context_entries.find_by!(entry_key: "conversation-comment-123").content).to include("Please add a test.")
    expect(run.spawn_requests.find_by!(asked_by: "github_pr_comment").context).to include("Please add a test.")
    expect(run.spawn_requests.find_by(requested_role: "git")).to have_attributes(write_scope: "git_managed")
  end

  it "only queues the continuation planner request, without touching git, for a run that has not published a PR yet" do
    workspace = Workspace.create!(name: "pr-resume-unpublished-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-resume-unpublished-#{SecureRandom.hex(4)}", task: "Resume before publishing",
      target_root: workspace.root_path, launcher_variant: "codex", status: "completed",
      phase: "awaiting_user_feedback", worktree_name: "resume-unpub-a1b2", branch_name: "workflow/resume-unpub-a1b2"
    )
    UserQuestion.create!(
      run_id: run.run_id, asked_by: "chaperone", scope: "workflow-plan.md", priority: "blocking",
      text: "Should this run stop here or retry?"
    )

    described_class.resume!(run, { "id" => 200, "body" => "Retry it.", "user" => { "login" => "reviewer" } })

    expect(run.reload).to have_attributes(status: "running", publication_status: "resume_requested")
    expect(run.spawn_requests.where(requested_role: "git")).to be_empty
    expect(run.spawn_requests.find_by!(asked_by: "github_pr_comment").context).to include("Retry it.")
  end

  it "routes a reply answering an open plan-approval question to ReplyReceivedTrigger instead of the mechanical answer path" do
    workspace = Workspace.create!(name: "pr-resume-plan-approval-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-resume-plan-approval-#{SecureRandom.hex(4)}", task: "Add a feature",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running",
      worktree_name: "plan-approval-resume-a1b2", branch_name: "workflow/plan-approval-resume-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9"
    )
    question = run.user_questions.create!(
      asked_by: "planner", scope: "run", priority: "blocking", status: "open",
      text: "Approve?", context: "The plan.", tags: [ "plan-approval" ]
    )
    comment = { "id" => 321, "body" => "why is this needed?", "user" => { "login" => "nicholasjstock" } }

    described_class.resume!(run, comment)

    review = ReplyReceivedReview.find_by(user_question_id: question.question_id)
    expect(review).to be_present
    expect(review.github_comment_body).to eq("why is this needed?")
    expect(SpawnRequest.find_by(run_id: run.run_id, requested_role: "reply_received", lineage_key: review.review_id)).to be_present

    # Never mechanically answered -- the reply_received review, not this
    # method, decides whether it counts as approval.
    expect(question.reload.status).to eq("open")
    expect(run.reload.last_pull_request_comment_id).to eq("321")
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

  it "reconciles with main on any comment wording, not just an exact merge-conflict phrase" do
    workspace = Workspace.create!(name: "pr-merge-conflict-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-merge-conflict-#{SecureRandom.hex(4)}", task: "Resolve conflict", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "merge-conflict-a1b2", branch_name: "workflow/merge-conflict-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    UserQuestion.create!(run_id: run.run_id, asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking", text: "Ready for review.")

    described_class.resume!(run, { "id" => 124, "body" => "Can you resolve the conflict with main?", "user" => { "login" => "reviewer" } })

    expect(run.reload).to have_attributes(status: "running", publication_status: "commit_pending")
    expect(run.spawn_requests.find_by(requested_role: "git")).to have_attributes(write_scope: "git_managed")
    expect(run.spawn_requests.find_by!(requested_role: "planner").context).to include("Can you resolve the conflict with main?")
  end

  it "answers only explicitly referenced questions and does not resume while another stays open" do
    workspace = Workspace.create!(name: "pr-question-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-question-#{SecureRandom.hex(4)}", task: "Answer from PR", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "question-a1b2", branch_name: "workflow/question-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Use the new setting?", priority: "blocking")
    other_question = build_second_open_blocking_question(run, text: "Keep this open?")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 999 }.to_json, "", status ])

    described_class.resume!(run, { "id" => 124, "body" => "Question #{question.question_id}: yes, use it", "user" => { "login" => "reviewer" } })

    expect(question.reload).to have_attributes(status: "answered", answered_by: "github:reviewer", answer_text: "yes, use it")
    expect(other_question.reload.status).to eq("open")
    expect(run.reload.status).to eq("completed")
    expect(Open3).to have_received(:capture3).with(
      anything, "gh", "api", "--method", "POST", anything, "-f", a_string_including(other_question.question_id)
    )
  end

  it "does not resume on a plain comment when more than one blocking question is open, and explains why" do
    workspace = Workspace.create!(name: "pr-ambiguous-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-ambiguous-#{SecureRandom.hex(4)}", task: "Ambiguous PR reply", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "ambiguous-a1b2", branch_name: "workflow/ambiguous-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    first_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Use the new setting?", priority: "blocking")
    second_question = build_second_open_blocking_question(run, text: "Keep this open?")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 999 }.to_json, "", status ])

    described_class.resume!(run, { "id" => 130, "body" => "Just move forward.", "user" => { "login" => "reviewer" } })

    expect(first_question.reload.status).to eq("open")
    expect(second_question.reload.status).to eq("open")
    expect(run.reload.status).to eq("completed")
    expect(Open3).to have_received(:capture3).with(
      anything, "gh", "api", "--method", "POST", anything, "-f",
      a_string_including(first_question.question_id).and(a_string_including(second_question.question_id))
    )
  end

  it "advances past its own unresolved-reply comment so it cannot poll and reply to itself" do
    workspace = Workspace.create!(name: "pr-self-reply-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-self-reply-#{SecureRandom.hex(4)}", task: "Ignore system reply", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "self-reply-a1b2", branch_name: "workflow/self-reply-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 999 }.to_json, "", status ])

    described_class.resume!(run, { "id" => 130, "body" => "Continue without an open question.", "user" => { "login" => "reviewer" } })

    expect(run.reload.last_pull_request_comment_id).to eq("999")
  end

  it "does not resume when an explicitly referenced question id is not open, and names the real open question" do
    workspace = Workspace.create!(name: "pr-mismatch-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-mismatch-#{SecureRandom.hex(4)}", task: "Mismatched question id", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "mismatch-a1b2", branch_name: "workflow/mismatch-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    real_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Use the new setting?", priority: "blocking")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 999 }.to_json, "", status ])
    bogus_id = SecureRandom.uuid

    described_class.resume!(run, { "id" => 131, "body" => "Question #{bogus_id}: yes", "user" => { "login" => "reviewer" } })

    expect(real_question.reload.status).to eq("open")
    expect(run.reload.status).to eq("completed")
    expect(Open3).to have_received(:capture3).with(
      anything, "gh", "api", "--method", "POST", anything, "-f",
      a_string_including(bogus_id).and(a_string_including(real_question.question_id))
    )
  end

  it "answering only an advisory question by id does not resume the run while a blocking question stays open" do
    workspace = Workspace.create!(name: "pr-advisory-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "pr-advisory-#{SecureRandom.hex(4)}", task: "Advisory-only answer", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "advisory-a1b2", branch_name: "workflow/advisory-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval"
    )
    advisory_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "FYI, using default.", priority: "advisory")
    blocking_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Keep this open?", priority: "blocking")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 999 }.to_json, "", status ])

    described_class.resume!(run, { "id" => 132, "body" => "Question #{advisory_question.question_id}: sure", "user" => { "login" => "reviewer" } })

    expect(advisory_question.reload.status).to eq("answered")
    expect(blocking_question.reload.status).to eq("open")
    expect(run.reload.status).to eq("completed")
  end

  it "polls and answers against an issue when the run has no PR yet" do
    workspace = Workspace.create!(name: "issue-resume-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "issue-resume-#{SecureRandom.hex(4)}", task: "Approve the plan", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "issue-resume-a1b2", branch_name: "workflow/issue-resume-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "planner", scope: "run", text: "Approve the plan?", priority: "blocking")
    status = instance_double(Process::Status, success?: true, exitstatus: 0)
    comments_json = [ { "id" => 456, "body" => "approved", "user" => { "login" => "operator" } } ].to_json
    allow(Open3).to receive(:capture3).with(anything, "gh", "api", "repos/example/repo/issues/9/comments?per_page=100")
      .and_return([ comments_json, "", status ])

    comments = described_class.comments_after(run)
    expect(comments.map { |c| c["id"] }).to eq([ 456 ])

    described_class.resume!(run, comments.first)

    expect(question.reload.status).to eq("answered")
    expect(run.reload).to have_attributes(status: "running", last_pull_request_comment_id: "456")
  end

  it "skips a deleted issue response without raising" do
    workspace = Workspace.create!(name: "issue-deleted-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "issue-deleted-#{SecureRandom.hex(4)}", task: "Deleted issue", target_root: workspace.root_path,
      launcher_variant: "codex", status: "completed", worktree_name: "issue-deleted-a1b2", branch_name: "workflow/issue-deleted-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open"
    )
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(Open3).to receive(:capture3).with(anything, "gh", "api", "repos/example/repo/issues/9/comments?per_page=100")
      .and_return([ { "message" => "Not Found", "status" => "404" }.to_json, "", status ])

    expect(described_class.comments_after(run)).to eq([])
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

  private

  # UserQuestion enforces at most one open blocking question per run (see
  # Run#open_blocking_question? and UserQuestion#at_most_one_open_blocking_question_per_run),
  # so a second one can't be created through the normal validated path.
  # This deliberately bypasses that to exercise resume!'s defensive
  # multiple-open-questions fallback, which still matters as a backstop for
  # data that predates the invariant or slips past it some other way.
  def build_second_open_blocking_question(run, text:)
    question = UserQuestion.new(run_id: run.run_id, asked_by: "worker", scope: "config", text: text, priority: "blocking")
    question.question_id = SecureRandom.uuid
    question.asked_at = Time.current
    question.save!(validate: false)
    question
  end
end
