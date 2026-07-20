require "rails_helper"

RSpec.describe AcceptanceCriterion do
  before do
    workspace = Workspace.create!(name: "criterion-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    @run = Run.create!(
      workspace:, run_id: "criterion-#{SecureRandom.hex(4)}", task: "Test criteria",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
  end

  it "requires a lowercase-hyphen key unique within the run" do
    described_class.create!(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "pending")

    duplicate = described_class.new(run_id: @run.run_id, key: "outcome", content: "Other.", status: "pending")
    assert_not duplicate.valid?

    invalid_format = described_class.new(run_id: @run.run_id, key: "Outcome!", content: "Other.", status: "pending")
    assert_not invalid_format.valid?
  end

  it "requires an evidence_ref when status is verified" do
    criterion = described_class.new(run_id: @run.run_id, key: "outcome", content: "Demo is faster.", status: "verified")
    assert_not criterion.valid?

    criterion.evidence_ref = "timings.json"
    assert criterion.valid?
  end

  it "is resolved once verified or waived, and not otherwise" do
    pending = described_class.create!(run_id: @run.run_id, key: "a", content: "A.", status: "pending")
    assert_not pending.resolved?

    verified = described_class.create!(run_id: @run.run_id, key: "b", content: "B.", status: "verified", evidence_ref: "ev.md")
    assert verified.resolved?

    waived = described_class.create!(run_id: @run.run_id, key: "c", content: "C.", status: "waived")
    assert waived.resolved?

    blocked = described_class.create!(run_id: @run.run_id, key: "d", content: "D.", status: "blocked")
    assert_not blocked.resolved?
  end

  it "resolves a parent only once every child is resolved, at any depth" do
    root = described_class.create!(run_id: @run.run_id, key: "root", content: "Root.", status: "pending")
    child = described_class.create!(run_id: @run.run_id, key: "child", parent: root, content: "Child.", status: "pending")
    grandchild = described_class.create!(run_id: @run.run_id, key: "grandchild", parent: child, content: "Grandchild.", status: "pending")

    assert_not root.resolved?

    grandchild.update!(status: "verified", evidence_ref: "ev.md")
    assert child.resolved?
    assert root.resolved?
  end
end
