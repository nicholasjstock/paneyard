require "rails_helper"

RSpec.describe AcceptanceCriterionStep do
  before do
    workspace = Workspace.create!(name: "criterion-step-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    @run = Run.create!(
      workspace:, run_id: "criterion-step-#{SecureRandom.hex(4)}", task: "Test criteria",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    @criterion = AcceptanceCriterion.create!(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "pending")
  end

  it "requires a lineage_key" do
    step = described_class.new(acceptance_criterion: @criterion, run_id: @run.run_id)
    assert_not step.valid?

    step.lineage_key = "demo-fix"
    assert step.valid?
  end

  it "is destroyed along with its criterion" do
    described_class.create!(acceptance_criterion: @criterion, run_id: @run.run_id, lineage_key: "demo-fix")

    assert_difference -> { described_class.count }, -1 do
      @criterion.destroy!
    end
  end
end
