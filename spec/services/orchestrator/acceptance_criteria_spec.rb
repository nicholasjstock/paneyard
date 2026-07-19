require "rails_helper"

RSpec.describe Orchestrator::AcceptanceCriteria do
  it "seeds durable outcome, demo, and measurement gates for a slow demo task" do
    root = Dir.mktmpdir("acceptance-criteria")
    workspace = Workspace.create!(name: "acceptance-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "acceptance-#{SecureRandom.hex(4)}", task: "Make the phone demo faster",
      target_root: root, launcher_variant: "claude", status: "launching"
    )

    described_class.seed!(run)

    expect(run.run_context_entries.where(kind: "acceptance_criterion").pluck(:entry_key)).to contain_exactly(
      "requested-outcome", "demo-artifact", "measured-performance"
    )
    expect(Orchestrator::RunContext.completion_blockers(run_id: run.run_id)).to contain_exactly(
      "requested-outcome", "demo-artifact", "measured-performance"
    )
  end

  it "rejects a report or tiny recording as demo evidence" do
    root = Dir.mktmpdir("demo-evidence")
    workspace = Workspace.create!(name: "evidence-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "evidence-#{SecureRandom.hex(4)}", task: "Record a demo",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    described_class.seed!(run)
    File.write(File.join(root, "report.md"), "The code changed.")
    File.binwrite(File.join(root, "tiny.webm"), "0" * 10_000)

    expect do
      Orchestrator::RunContext.upsert!(
        run_id: run.run_id, entry_key: "demo-artifact", kind: "acceptance_criterion", status: "verified",
        content: "Demo exists", evidence_ref: "report.md", created_by: "worker"
      )
    end.to raise_error(ArgumentError, /video artifact/)
    expect do
      Orchestrator::RunContext.upsert!(
        run_id: run.run_id, entry_key: "demo-artifact", kind: "acceptance_criterion", status: "verified",
        content: "Demo exists", evidence_ref: "tiny.webm", created_by: "worker"
      )
    end.to raise_error(ArgumentError, /at least 100000 bytes/)
  end

  it "accepts a substantial workspace video as demo evidence" do
    root = Dir.mktmpdir("demo-evidence")
    workspace = Workspace.create!(name: "evidence-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "evidence-#{SecureRandom.hex(4)}", task: "Record a demo",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    described_class.seed!(run)
    File.binwrite(File.join(root, "phone.webm"), "0" * 100_001)

    entry = Orchestrator::RunContext.upsert!(
      run_id: run.run_id, entry_key: "demo-artifact", kind: "acceptance_criterion", status: "verified",
      content: "Demo exists", evidence_ref: "phone.webm", created_by: "worker"
    )

    expect(entry.status).to eq("verified")
  end
end
