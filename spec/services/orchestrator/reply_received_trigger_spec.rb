require "rails_helper"

RSpec.describe Orchestrator::ReplyReceivedTrigger do
  it "issues a review and a blocking reply_received spawn request scoped to it" do
    run = create_run
    question = create_question(run)
    comment = { "id" => 7, "user" => { "login" => "nicholasjstock" }, "body" => "not sure why this is needed" }

    review = described_class.call(question:, comment:)

    expect(review).to be_a(ReplyReceivedReview)
    expect(review.status).to eq("queued")

    request = SpawnRequest.find_by(run_id: run.run_id, requested_role: "reply_received")
    expect(request).to be_present
    expect(request.lineage_key).to eq(review.review_id)
    expect(request.scope).to eq(review.review_id)
    expect(request.priority).to eq("blocking")
    expect(request.context).to include("not sure why this is needed")
  end

  it "revives a completed pull-request review run so its reply can be dispatched" do
    run = create_run
    run.update!(status: "completed", publication_status: "awaiting_approval")
    Orchestrator::TickState.write(
      run_id: run.run_id, phase: "completed", tick_count: 1, last_plan_summary: nil,
      pending_spawn_keys: [], following_steps: [], last_stall_finding: nil
    )
    question = run.user_questions.create!(
      asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking", status: "open",
      text: "This run's work is ready for review."
    )

    described_class.call(question:, comment: { "id" => 8, "user" => { "login" => "nicholasjstock" }, "body" => "Please change the wording." })

    expect(run.reload).to have_attributes(status: "running", publication_status: "resume_requested")
    expect(Orchestrator::TickState.latest(run.run_id)[:phase]).to eq("planning")
  end

  def create_run
    root = Dir.mktmpdir("reply-received-trigger")
    workspace = Workspace.create!(name: "reply-received-trigger-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "reply-received-trigger-#{SecureRandom.hex(4)}", task: "Add a feature",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end

  def create_question(run)
    run.user_questions.create!(
      asked_by: "planner", scope: "run", priority: "blocking", status: "open",
      text: "Approve?", context: "The plan.", tags: [ "plan-approval" ]
    )
  end
end
