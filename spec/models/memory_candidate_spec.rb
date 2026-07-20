require "rails_helper"

RSpec.describe MemoryCandidate, type: :model do
  it "requires the core fields and validates status" do
    run = create_run

    candidate = MemoryCandidate.new(
      run_id: run.run_id, lineage_key: "some-lineage", status: "proposed",
      approach: "Tried running `npm start` from the repo root.", reason: "No package.json exists there."
    )

    expect(candidate).to be_valid
    expect(candidate.candidate_id).to be_present
  end

  it "rejects a status outside the allowed set" do
    run = create_run

    candidate = MemoryCandidate.new(
      run_id: run.run_id, lineage_key: "some-lineage", status: "confirmed",
      approach: "Tried X.", reason: "It failed."
    )

    expect(candidate).not_to be_valid
    expect(candidate.errors[:status]).to be_present
  end

  it "requires approach and reason" do
    run = create_run

    candidate = MemoryCandidate.new(run_id: run.run_id, lineage_key: "some-lineage", status: "proposed")

    expect(candidate).not_to be_valid
    expect(candidate.errors[:approach]).to be_present
    expect(candidate.errors[:reason]).to be_present
  end

  def create_run
    root = Dir.mktmpdir("memory-candidate-model")
    workspace = Workspace.create!(name: "memory-candidate-model-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "memory-candidate-model-#{SecureRandom.hex(4)}", task: "Exercise MemoryCandidate validations",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
