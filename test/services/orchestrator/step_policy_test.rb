require "test_helper"

class Orchestrator::StepPolicyTest < ActiveSupport::TestCase
  test "rejects an executable step assigned to the orchestrator" do
    error = assert_raises ArgumentError do
      Orchestrator::StepPolicy.validate!(
        run_id: "unused",
        step: {
          owner: "orchestrator", artifact: "verification.md", success_check: "Verify behavior.",
          mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
        }
      )
    end

    assert_equal "Planner step must name an executable owner", error.message
  end

  test "normalizes excess path authority away from non-writing steps" do
    plan = Orchestrator::StepPolicy.normalize_plan(
      next_step: {
        mode: "verification", write_scope: "artifact_only",
        allowed_paths: [ "front/scripts/record-demo.ts" ]
      },
      following_steps: [
        { mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [ "front/" ] }
      ]
    )

    assert_empty plan[:next_step][:allowed_paths]
    assert_empty plan[:following_steps].first[:allowed_paths]
  end

  test "does not infer or alter implementation paths" do
    plan = Orchestrator::StepPolicy.normalize_plan(
      next_step: {
        mode: "implementation", write_scope: "scoped_changes",
        allowed_paths: [ "front/**/*.ts" ]
      }, following_steps: []
    )

    assert_equal [ "front/**/*.ts" ], plan[:next_step][:allowed_paths]
  end

  setup do
    workspace = Workspace.create!(name: "step-policy-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    @run = Run.create!(
      workspace:,
      run_id: "step-policy-#{SecureRandom.hex(4)}",
      task: "Test planner evidence boundaries",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
  end

  test "rejects a diagnosis step that also requests implementation" do
    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: @run.run_id,
        step: diagnosis_step(success_check: "Reproduce the response, then implement the smallest fix.")
      )
    end

    assert_equal "diagnosis step cannot also request implementation", error.message
  end

  test "allows a diagnosis step to explicitly prohibit changes" do
    step = diagnosis_step(success_check: "Reproduce the boundary. Do not change application code or public contracts.")

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  test "rejects implementation without evidence and exact files" do
    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: @run.run_id,
        step: {
          owner: "worker", artifact: "fix.md", success_check: "Correct the confirmed defect.",
          mode: "implementation", write_scope: "scoped_changes", allowed_paths: [ "back/**" ], evidence_refs: []
        }
      )
    end

    assert_match(/allowedPaths must name exact files/, error.message)
  end

  test "rejects protected API files without answered operator approval" do
    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: @run.run_id,
        step: implementation_step(allowed_paths: [ "openapi.yaml" ])
      )
    end

    assert_match(/Protected paths require an answered operator question/, error.message)
  end

  test "accepts a protected API file after explicit operator approval" do
    question = @run.user_questions.create!(
      asked_by: "planner", scope: "api-contract.md", text: "Approve the documented OpenAPI contract update?",
      priority: "blocking", status: "answered", answered_by: "operator", answered_at: Time.current,
      answer_text: "Approved: update openapi.yaml for this response contract."
    )
    step = implementation_step(
      allowed_paths: [ "openapi.yaml" ],
      operator_approval_question_id: question.question_id
    )

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  private

  def diagnosis_step(success_check: "Capture the POST and GET responses and report the failing boundary.")
    {
      owner: "worker", artifact: "diagnosis.md", success_check:,
      mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
    }
  end

  def implementation_step(allowed_paths:, operator_approval_question_id: nil)
    {
      owner: "worker", artifact: "fix.md", success_check: "Correct the confirmed defect.",
      mode: "implementation", write_scope: "scoped_changes", allowed_paths:,
      evidence_refs: [ "diagnosis.md#confirmed-boundary" ], operator_approval_question_id:
    }
  end
end
