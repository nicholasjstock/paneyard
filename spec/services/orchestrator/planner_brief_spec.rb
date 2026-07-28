require "rails_helper"

RSpec.describe Orchestrator::PlannerBrief do
  it "includes an answered question's answer text, and keeps open_questions limited to still-open ones" do
    workspace = Workspace.create!(name: "planner-brief-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "planner-brief-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    answered = UserQuestion.create!(
      run_id: run.run_id, asked_by: "planner", scope: "run", priority: "blocking", text: "Approve the plan?",
      status: "answered", answered_by: "operator", answered_at: Time.current, answer_text: "Distinctive-answer-text-xyz"
    )
    open_question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Still open?", priority: "advisory")

    prompt = Orchestrator::PlannerBrief.build(run:, request:)
    payload = JSON.parse(prompt[prompt.index('{"run":')..])

    expect(payload["recent_answered_questions"].pluck("questionId")).to eq([ answered.question_id ])
    expect(payload["recent_answered_questions"].first["answerText"]).to eq("Distinctive-answer-text-xyz")
    expect(payload["open_questions"].pluck("questionId")).to eq([ open_question.question_id ])
  end
end
