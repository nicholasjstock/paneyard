require "rails_helper"

RSpec.describe RunContextEntry do
  it "accepts artifact_inheritance_graph as a valid kind" do
    entry = RunContextEntry.new(
      run_id: "test-run",
      entry_key: "artifact_inheritance_test",
      kind: "artifact_inheritance_graph",
      status: "confirmed",
      content: "Worker A produced artifact X",
      created_by: "orchestrator"
    )
    expect(entry).to be_valid
  end

  it "enforces presence of required fields" do
    entry = RunContextEntry.new(kind: "artifact_inheritance_graph")
    expect(entry).not_to be_valid
    expect(entry.errors[:run_id]).to be_present
    expect(entry.errors[:entry_key]).to be_present
    expect(entry.errors[:status]).to be_present
    expect(entry.errors[:content]).to be_present
    expect(entry.errors[:created_by]).to be_present
  end

  it "enforces uniqueness of entry_key within a run" do
    run_id = "test-run-#{SecureRandom.hex(4)}"
    first = RunContextEntry.create!(
      run_id: run_id,
      entry_key: "unique_key",
      kind: "fact",
      status: "confirmed",
      content: "First entry",
      evidence_ref: "test.md",
      created_by: "orchestrator"
    )
    second = RunContextEntry.new(
      run_id: run_id,
      entry_key: "unique_key",
      kind: "fact",
      status: "confirmed",
      content: "Second entry",
      evidence_ref: "test.md",
      created_by: "orchestrator"
    )
    expect(second).not_to be_valid
    expect(second.errors[:entry_key]).to include("has already been taken")
  end

  it "returns properly formatted JSON representation" do
    now = Time.current
    entry = RunContextEntry.create!(
      run_id: "test-run",
      entry_key: "test_key",
      kind: "artifact_inheritance_graph",
      status: "confirmed",
      content: "Test content",
      created_by: "orchestrator",
      updated_at: now
    )
    json = entry.as_json
    expect(json[:key]).to eq("test_key")
    expect(json[:kind]).to eq("artifact_inheritance_graph")
    expect(json[:status]).to eq("confirmed")
    expect(json[:content]).to eq("Test content")
    expect(json[:createdBy]).to eq("orchestrator")
  end
end
