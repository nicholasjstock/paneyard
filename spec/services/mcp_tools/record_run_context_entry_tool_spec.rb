require "rails_helper"

RSpec.describe McpTools::RecordRunContextEntryTool do
  it "creates a curated run-context entry" do
    root = Dir.mktmpdir("context-tool")
    workspace = Workspace.create!(name: "context-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "context-#{SecureRandom.hex(4)}", task: "Verify it",
      target_root: root, launcher_variant: "claude", status: "running"
    )

    response = described_class.call(
      runId: run.run_id, key: "outcome", kind: "fact", status: "confirmed",
      content: "Worker says done", createdBy: "worker", evidenceRef: "report.md", server_context: nil
    )

    expect(response.error?).to be_falsey
    entry = RunContextEntry.find_by!(run_id: run.run_id, entry_key: "outcome")
    expect(entry.kind).to eq("fact")
    expect(entry.evidence_ref).to eq("report.md")
  end

  it "updates an existing entry with the same key" do
    root = Dir.mktmpdir("context-tool")
    workspace = Workspace.create!(name: "context-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "context-#{SecureRandom.hex(4)}", task: "Verify it",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    described_class.call(
      runId: run.run_id, key: "note", kind: "constraint", status: "confirmed",
      content: "First version", createdBy: "worker", server_context: nil
    )

    described_class.call(
      runId: run.run_id, key: "note", kind: "constraint", status: "confirmed",
      content: "Updated version", createdBy: "worker", server_context: nil
    )

    expect(RunContextEntry.where(run_id: run.run_id, entry_key: "note").count).to eq(1)
    expect(RunContextEntry.find_by!(run_id: run.run_id, entry_key: "note").content).to eq("Updated version")
  end
end
