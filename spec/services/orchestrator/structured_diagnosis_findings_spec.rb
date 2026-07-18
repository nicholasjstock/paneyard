require "rails_helper"

RSpec.describe Orchestrator::StructuredDiagnosisFindings do
  it "persists exact targets and measurements as one curated run-context fact" do
    root = Dir.mktmpdir("structured-findings")
    FileUtils.mkdir_p(File.join(root, "front", "scripts"))
    File.write(File.join(root, "front", "scripts", "record-demo.ts"), "// target")
    workspace = Workspace.create!(name: "findings-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(run_id: SecureRandom.uuid, task: "Make the demo faster", target_root: root, launcher_variant: "claude", status: "running")
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker", reason: "Measure it.", scope: "diagnosis.md",
      status: "running", pid: 123_456, command: "claude", args: [], prompt_path: File.join(root, "prompt"),
      log_path: File.join(root, "log"), last_message_path: File.join(root, "last"), env_path: File.join(root, "env")
    )
    run.spawn_requests.create!(
      asked_by: "planner", scope: worker.scope, text: "Execution mode: diagnosis. Measure it.", requested_role: "worker",
      priority: "blocking", status: "fulfilled", fulfilled_worker_id: worker.worker_id, lineage_key: "demo-performance"
    )
    Orchestrator::ArtifactStore.write(
      root, run.run_id, worker.scope,
      "Target front/scripts/record-demo.ts. Typical runtime measured at 300 seconds."
    )

    Orchestrator::StructuredDiagnosisFindings.persist!(
      run_id: run.run_id, nickname: worker.nickname, scope: worker.scope,
      findings: {
        target_paths: [ "front/scripts/record-demo.ts" ],
        measurements: [ { name: "typical_runtime", value: 300, unit: "seconds" } ],
        objective: "Reduce phone-demo runtime below 200 seconds"
      }
    )

    entry = run.run_context_entries.find_by!(kind: "fact")
    content = JSON.parse(entry.content)
    assert_equal [ "front/scripts/record-demo.ts" ], content.fetch("target_paths")
    assert_equal 300.0, content.fetch("measurements").first.fetch("value")
    assert_equal worker.scope, entry.evidence_ref
    assert_includes Orchestrator::PlannerBrief.build(run:, request: run.spawn_requests.first), "front/scripts/record-demo.ts"
  end

  it "rejects a target path that is not cited in the diagnosis artifact" do
    root = Dir.mktmpdir("structured-findings-reject")
    workspace = Workspace.create!(name: "findings-reject-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(run_id: SecureRandom.uuid, task: "Diagnose", target_root: root, launcher_variant: "claude", status: "running")
    Orchestrator::ArtifactStore.write(root, run.run_id, "diagnosis.md", "No target established.")

    error = assert_raises(ArgumentError) do
      Orchestrator::StructuredDiagnosisFindings.persist!(
        run_id: run.run_id, nickname: "worker", scope: "diagnosis.md",
        findings: { target_paths: [ "front/scripts/record-demo.ts" ] }
      )
    end
    assert_includes error.message, "not cited"
  end
end
