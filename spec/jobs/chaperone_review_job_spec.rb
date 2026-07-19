require "rails_helper"

RSpec.describe ChaperoneReviewJob do
  it "fails the review and reconciles its awaiting planner decision when the chaperone subprocess errors" do
    run = create_run
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "workflow-plan.md", text: "Plan the next step.",
      requested_role: "planner", priority: "blocking"
    )
    decision = run.planner_decisions.create!(spawn_request: request, status: "awaiting_chaperone")
    review, token = ChaperoneReview.issue!(
      run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [],
      subject_type: "planner", subject_id: decision.decision_id, summary: "Protected path proposed"
    )
    failed_status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(Open3).to receive(:capture3).and_return([ "", "boom: killed", failed_status ])

    expect { ChaperoneReviewJob.perform_now(review.id, token) }.to raise_error(/Chaperone exited/)

    expect(review.reload.status).to eq("failed")
    expect(decision.reload.status).to eq("failed")
    expect(UserQuestion.find_by(run_id: run.run_id, priority: "blocking", status: "open")).to be_present
    expect(run.reload.phase).to eq("blocked_on_user")
  end

  def create_run
    root = Dir.mktmpdir("chaperone-review-job")
    workspace = Workspace.create!(name: "chaperone-review-job-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "chaperone-review-job-#{SecureRandom.hex(4)}", task: "Exercise chaperone execution failure",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
