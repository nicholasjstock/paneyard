require "rails_helper"

RSpec.describe Orchestrator::ApplyReplyReceivedDecision do
  describe ".call" do
    it "approved: dispatches the exact gated step instead of asking a fresh planner to reconstruct it" do
      run = create_run
      next_step = gated_step("fix.md")
      following_step = gated_step("verify.md", mode: "verification", write_scope: "source_protected")
      question = create_question(run, next_step:, following_steps: [ following_step ])
      review = create_review(run:, question:, body: "approved")

      described_class.call(review:, action: "approved", summary: "The operator gave a clean sign-off.")

      question.reload
      expect(question.status).to eq("answered")
      expect(question.answered_by).to eq("reply_received")
      expect(question.tags).to include("granted")
      expect(run.reload.publication_status).to eq("resume_requested")
      expect(run.phase).to eq("planning")
      worker = SpawnRequest.find_by!(run_id: run.run_id, requested_role: "worker", scope: "fix.md")
      expect(worker).to have_attributes(execution_mode: "implementation", write_scope: "scoped_changes")
      expect(SpawnRequest.where(run_id: run.run_id, requested_role: "planner", asked_by: "reply_received")).to be_empty
      expect(Orchestrator::TickState.latest(run.run_id)[:following_steps]).to include(include(artifact: "verify.md"))
      expect(review.reload.status).to eq("completed")
      expect(review.action).to eq("approved")

      # Once granted, the gate must never re-fire for this run's lifetime.
      expect(
        Orchestrator::PlanApprovalQuestion.send(
          :applicable?, run: run.reload,
          next_step: { write_scope: "scoped_changes", artifact: "x.md", mode: "implementation", allowed_paths: [], addresses_criteria: [], success_check: "x" }
        )
      ).to be(false)
    end

    it "approved: rejects a plan-approval question missing its durable gated step" do
      run = create_run
      question = create_question(run)
      review = create_review(run:, question:, body: "approved")

      expect {
        described_class.call(review:, action: "approved", summary: "The operator gave a clean sign-off.")
      }.to raise_error(ArgumentError, /has no gated next step/)
    end

    it "explain: closes the original question without granting approval and re-opens a fresh plan-approval question carrying the explanation" do
      run = create_run
      question = create_question(run)
      review = create_review(run:, question:, body: "why is this needed?")

      described_class.call(
        review:, action: "explain", summary: "Explained the design.",
        explanation: "Because runs are immutable once executing, so a child investigation needs its own run row."
      )

      question.reload
      expect(question.status).to eq("answered")
      expect(question.tags).not_to include("granted")

      fresh = run.user_questions.plan_approval.open_only.first
      expect(fresh).to be_present
      expect(fresh.text).to include("Because runs are immutable once executing")
      expect(fresh.tags).to eq([ "plan-approval" ])
      expect(run.reload.phase).to eq("awaiting_user_feedback")

      # Still blocked -- explain never grants the gate, so it must stay
      # inapplicable while the fresh question is open, and the run has no
      # "granted" tag anywhere yet.
      expect(run.open_blocking_question?).to be(true)
    end

    it "revise: closes the original question, sends the objection to a fresh planner turn, and leaves the gate re-openable" do
      run = create_run
      question = create_question(run)
      review = create_review(run:, question:, body: "this is the wrong approach entirely")

      described_class.call(review:, action: "revise", summary: "The proposed approach does not satisfy the request.")

      question.reload
      expect(question.status).to eq("answered")
      expect(question.tags).not_to include("granted")
      expect(run.open_blocking_question?).to be(false)

      replan = SpawnRequest.find_by!(run_id: run.run_id, requested_role: "planner", asked_by: "reply_received")
      expect(replan.context).to include("does not satisfy the request")
      expect(replan.tags).to include("revise")
      expect(run.reload.phase).to eq("planning")

      # No "granted" tag exists yet, and the run has no open blocking
      # question -- the gate must be able to re-fire on the planner's
      # revised next_step.
      expect(
        Orchestrator::PlanApprovalQuestion.send(
          :applicable?, run: run,
          next_step: { write_scope: "scoped_changes", artifact: "x.md", mode: "implementation", allowed_paths: [], addresses_criteria: [], success_check: "x" }
        )
      ).to be(true)
    end

    it "pull-request review revise: resumes planning without re-publishing the unchanged pull request" do
      run = create_run
      run.update!(status: "completed", pull_request_url: "https://github.com/example/repo/pull/42", publication_status: "awaiting_approval")
      question = run.user_questions.create!(
        asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking", status: "open",
        text: "This run's work is ready for review."
      )
      review = create_review(run:, question:, body: "Use the issue title instead of this generic wording.")

      described_class.call(review:, action: "revise", summary: "The review prompt needs the issue or PR title.")

      expect(question.reload.status).to eq("answered")
      expect(run.reload).to have_attributes(status: "running", publication_status: "resume_requested", phase: "planning")
      expect(Orchestrator::TickState.latest(run.run_id)[:phase]).to eq("planning")
      replan = SpawnRequest.find_by!(run_id: run.run_id, requested_role: "planner", asked_by: "reply_received")
      expect(replan.context).to include("issue or PR title")
      expect(run.spawn_requests.where(requested_role: "git")).to be_empty
    end

    it "rejects explain without an explanation" do
      run = create_run
      question = create_question(run)
      review = create_review(run:, question:, body: "why?")

      expect {
        described_class.call(review:, action: "explain", summary: "no explanation given")
      }.to raise_error(ArgumentError, /explanation/)
    end
  end

  def create_run
    root = Dir.mktmpdir("apply-reply-received-decision")
    workspace = Workspace.create!(name: "apply-reply-received-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "apply-reply-received-#{SecureRandom.hex(4)}", task: "Add a feature",
      target_root: root, launcher_variant: "claude", status: "running",
      worktree_name: "apply-reply-received-a1b2", branch_name: "workflow/apply-reply-received-a1b2"
    )
  end

  def create_question(run, next_step: nil, following_steps: [])
    run.user_questions.create!(
      asked_by: "planner", scope: "run", priority: "blocking", status: "open",
      text: "Approve?", context: "The plan.", tags: [ "plan-approval" ],
      gated_next_step: next_step&.deep_stringify_keys || {},
      gated_following_steps: following_steps.map(&:deep_stringify_keys)
    )
  end

  def gated_step(artifact, mode: "implementation", write_scope: "scoped_changes")
    {
      owner: "worker", artifact:, mode:, write_scope:,
      allowed_paths: write_scope == "source_protected" ? [] : [ "app/models/user_question.rb" ],
      evidence_refs: mode == "implementation" ? [ "diagnosis.md" ] : [],
      addresses_criteria: [], lineage_key: artifact, success_check: "Exercise #{artifact}."
    }
  end

  def create_review(run:, question:, body:)
    review, = ReplyReceivedReview.issue!(
      run:, user_question: question, comment: { "id" => 1, "user" => { "login" => "nicholasjstock" }, "body" => body }
    )
    review.update!(status: "running")
    review
  end
end
