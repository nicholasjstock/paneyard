require "test_helper"

class Orchestrator::ObjectiveAlignmentTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "rejects a performance diagnosis without a cited numeric baseline and preserves it as unrelated evidence" do
    run, request, worker = build_diagnosis("Make the phone demo faster")
    artifact = "The phone demo has a nested coverage-item routing defect in front/scripts/record-demo.ts."
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, request.scope, artifact)

    error = assert_raises(ArgumentError) do
      Orchestrator::DiagnosisEvidenceGate.validate!(
        run_id: run.run_id, nickname: worker.nickname, scope: request.scope,
        evidence_outcome: "confirmed", evidence_citations: [ artifact ]
      )
    end

    assert_includes error.message, "numeric baseline"
    rejected = RunContextEntry.find_by!(run_id: run.run_id, kind: "rejected_approach")
    assert_equal request.scope, rejected.evidence_ref
    assert_includes rejected.content, "separate candidate"
  end

  test "queues a chaperone after a second objective-misaligned diagnosis in one lineage" do
    run, first_request, first_worker = build_diagnosis("Make the phone demo faster")
    reject_diagnosis(run, first_request, first_worker)
    second_worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-2", reason: "Retry diagnosis.",
      scope: "diagnosis-2.md", status: "running", pid: 123_457, command: "claude", args: [],
      prompt_path: File.join(run.target_root, "prompt-2"), log_path: File.join(run.target_root, "log-2"),
      last_message_path: File.join(run.target_root, "last-2"), env_path: File.join(run.target_root, "env-2")
    )
    second_request = run.spawn_requests.create!(
      asked_by: "planner", scope: second_worker.scope,
      text: "Execution mode: diagnosis. Record a measured baseline.", requested_role: "worker",
      priority: "blocking", status: "fulfilled", fulfilled_worker_id: second_worker.worker_id,
      lineage_key: first_request.lineage_key
    )

    assert_enqueued_with(job: ChaperoneReviewJob) do
      reject_diagnosis(run, second_request, second_worker)
    end

    assert_equal "queued", run.chaperone_reviews.last.status
    assert_equal 2, run.chaperone_reviews.last.step_attempt_ids.length
  end

  test "accepts a performance diagnosis with an artifact-backed measurement" do
    run, request, worker = build_diagnosis("Make the phone demo faster")
    citation = "Measured phone demo duration: 94.2 seconds from launch to completion."
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, request.scope, citation)

    assert_nothing_raised do
      Orchestrator::DiagnosisEvidenceGate.validate!(
        run_id: run.run_id, nickname: worker.nickname, scope: request.scope,
        evidence_outcome: "confirmed", evidence_citations: [ citation ]
      )
    end
  end

  test "rejects downstream work that drops the performance objective" do
    run, = build_diagnosis("Make the phone demo faster")

    error = assert_raises(ArgumentError) do
      Orchestrator::StepPolicy.validate!(
        run_id: run.run_id,
        step: {
          owner: "worker", artifact: "fix.md", success_check: "Correct nested coverage-item routing.",
          mode: "implementation", write_scope: "scoped_changes",
          allowed_paths: [ "front/scripts/record-demo.ts" ], evidence_refs: [ "initial-diagnosis.md" ]
        }
      )
    end

    assert_includes error.message, "performance objective"
  end

  private

  def reject_diagnosis(run, request, worker)
    citation = "The phone demo has a nested coverage routing defect."
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, request.scope, citation)
    assert_raises(Orchestrator::ObjectiveAlignment::Error) do
      Orchestrator::DiagnosisEvidenceGate.validate!(
        run_id: run.run_id, nickname: worker.nickname, scope: request.scope,
        evidence_outcome: "confirmed", evidence_citations: [ citation ]
      )
    end
  end

  def build_diagnosis(task)
    root = Dir.mktmpdir("objective-alignment")
    workspace = Workspace.create!(name: "alignment-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(run_id: SecureRandom.uuid, task:, target_root: root, launcher_variant: "claude", status: "running")
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker", reason: "Diagnose performance.",
      scope: "diagnosis.md", status: "running", pid: 123_456, command: "claude", args: [],
      prompt_path: File.join(root, "prompt"), log_path: File.join(root, "log"),
      last_message_path: File.join(root, "last"), env_path: File.join(root, "env")
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: worker.scope,
      text: "Execution mode: diagnosis. Identify the target and record a measured baseline.",
      requested_role: "worker", priority: "blocking", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      lineage_key: "phone-demo-performance"
    )
    [ run, request, worker ]
  end
end
