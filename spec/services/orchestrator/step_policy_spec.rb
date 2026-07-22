require "rails_helper"

RSpec.describe Orchestrator::StepPolicy do
  it "rejects an executable step assigned to the orchestrator" do
    error = assert_raises ArgumentError do
      Orchestrator::StepPolicy.validate!(
        run_id: "unused",
        step: {
          owner: "orchestrator", artifact: "verification.md", success_check: "Verify behavior.",
          mode: "verification", write_scope: "source_protected", allowed_paths: [], evidence_refs: []
        }
      )
    end

    assert_equal "Planner step must name an executable owner", error.message
  end

  it "normalizes excess path authority away from non-writing steps" do
    plan = Orchestrator::StepPolicy.normalize_plan(
      next_step: {
        mode: "verification", write_scope: "source_protected",
        allowed_paths: [ "front/scripts/record-demo.ts" ]
      },
      following_steps: [
        { mode: "diagnosis", write_scope: "source_protected", allowed_paths: [ "front/" ] }
      ]
    )

    assert_empty plan[:next_step][:allowed_paths]
    assert_empty plan[:following_steps].first[:allowed_paths]
  end

  it "does not infer or alter implementation paths" do
    plan = Orchestrator::StepPolicy.normalize_plan(
      next_step: {
        mode: "implementation", write_scope: "scoped_changes",
        allowed_paths: [ "front/**/*.ts" ]
      }, following_steps: []
    )

    assert_equal [ "front/**/*.ts" ], plan[:next_step][:allowed_paths]
  end

  before do
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

  it "rejects a diagnosis step that also requests implementation" do
    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: @run.run_id,
        step: diagnosis_step(success_check: "Reproduce the response, then implement the smallest fix.")
      )
    end

    assert_equal "diagnosis step cannot also request implementation", error.message
  end

  it "allows a diagnosis step to explicitly prohibit changes" do
    step = diagnosis_step(success_check: "Reproduce the boundary. Do not change application code or public contracts.")

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  it "rejects implementation without evidence, even when no planner file list is supplied" do
    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: @run.run_id,
        step: {
          owner: "worker", artifact: "fix.md", success_check: "Correct the confirmed defect.",
          mode: "implementation", write_scope: "scoped_changes", allowed_paths: [], evidence_refs: []
        }
      )
    end

    assert_match(/requires at least one evidenceRef/, error.message)
  end

  it "allows implementation with no planner-provided file list" do
    @run.workspace.update!(protected_path_patterns: [ "." ])

    step = implementation_step(allowed_paths: [])

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  it "is a no-op when the run has no acceptance criteria" do
    step = diagnosis_step

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  it "rejects a step that names no acceptance criteria once a contract exists" do
    AcceptanceCriterion.create!(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "pending")

    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step: diagnosis_step)
    end

    assert_equal "Planner step must name which acceptance criteria it addresses (addressesCriteria)", error.message
  end

  it "rejects a step that references an unknown acceptance criterion key" do
    AcceptanceCriterion.create!(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "pending")

    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step: diagnosis_step(addresses_criteria: [ "missing" ]))
    end

    assert_match(/addressesCriteria names unknown criteria: missing/, error.message)
  end

  it "accepts a step referencing a real current key, including a nested child" do
    root = AcceptanceCriterion.create!(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "pending")
    AcceptanceCriterion.create!(run_id: @run.run_id, key: "outcome-sub", parent: root, content: "Sub-goal.", status: "pending")

    step = diagnosis_step(addresses_criteria: [ "outcome-sub" ])

    assert_equal step, Orchestrator::StepPolicy.validate!(run_id: @run.run_id, step:)
  end

  private

  def diagnosis_step(success_check: "Capture the POST and GET responses and report the failing boundary.", addresses_criteria: [])
    {
      owner: "worker", artifact: "diagnosis.md", success_check:,
      mode: "diagnosis", write_scope: "source_protected", allowed_paths: [], evidence_refs: [],
      addresses_criteria:
    }
  end

  def implementation_step(allowed_paths:)
    {
      owner: "worker", artifact: "fix.md", success_check: "Correct the confirmed defect.",
      mode: "implementation", write_scope: "scoped_changes", allowed_paths:,
      evidence_refs: [ "diagnosis.md#confirmed-boundary" ]
    }
  end
end
