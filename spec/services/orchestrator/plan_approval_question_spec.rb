require "rails_helper"

RSpec.describe Orchestrator::PlanApprovalQuestion do
  it "builds a question whose context carries the verbatim task, the criteria tree, diagnosis findings, and the proposed step" do
    workspace = Workspace.create!(name: "plan-approval-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "plan-approval-#{SecureRandom.hex(4)}", task: "Distinctive-verbatim-task-text-xyz",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "plan-approval-a1b2", branch_name: "workflow/plan-approval-a1b2"
    )
    AcceptanceCriterion.create!(run_id: run.run_id, key: "distinctive-criterion", status: "pending", content: "Distinctive criterion content")
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    run.step_attempts.create!(
      attempt_id: SecureRandom.uuid, lineage_key: "diagnose-it", mode: "diagnosis", outcome: "done",
      result: "[DONE] Distinctive diagnosis finding text.", spawn_request_id: request.request_id
    )
    RunContextEntry.create!(
      run_id: run.run_id, entry_key: "diagnosis-findings-diagnose-it", kind: "fact", status: "confirmed",
      content: "Distinctive structured findings content.", created_by: "worker", evidence_ref: "diagnose-it"
    )
    next_step = {
      artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes",
      allowed_paths: [ "app/models/example.rb" ], addresses_criteria: [ "distinctive-criterion" ],
      success_check: "Distinctive success check text."
    }

    question = described_class.ask!(decision:, next_step:, following_steps: [])

    expect(question.context).to include("Distinctive-verbatim-task-text-xyz")
    expect(question.context).to include("distinctive-criterion")
    expect(question.context).to include("Distinctive criterion content")
    expect(question.context).to include("Distinctive diagnosis finding text")
    expect(question.context).to include("Distinctive structured findings content")
    expect(question.context).to include("fix.md")
    expect(question.context).to include("app/models/example.rb")
    expect(question.context).to include("Distinctive success check text")
    expect(question.tags).to eq([ "plan-approval" ])
  end

  it "requests a plan-summary reporter, uniquely scoped per question, alongside the blocking question" do
    workspace = Workspace.create!(name: "plan-approval-reporter-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "plan-approval-reporter-#{SecureRandom.hex(4)}", task: "Task",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "plan-approval-reporter-a1b2", branch_name: "workflow/plan-approval-reporter-a1b2"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    next_step = { artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes", allowed_paths: [], addresses_criteria: [], success_check: "check" }

    question = described_class.ask!(decision:, next_step:, following_steps: [])

    reporter_request = run.spawn_requests.find_by!(requested_role: "reporter")
    expect(reporter_request.scope).to eq("plan-summary-#{question.question_id}.md")
    expect(reporter_request.priority).to eq("blocking")
    expect(reporter_request.write_scope).to eq("source_protected")
  end

  it "truncates long values at the declared constants" do
    workspace = Workspace.create!(name: "plan-approval-truncate-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "plan-approval-truncate-#{SecureRandom.hex(4)}", task: "a" * 10_000,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "plan-approval-truncate-a1b2", branch_name: "workflow/plan-approval-truncate-a1b2"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    run.step_attempts.create!(
      attempt_id: SecureRandom.uuid, lineage_key: "diagnose-it", mode: "diagnosis", outcome: "done",
      result: "b" * 10_000, spawn_request_id: request.request_id
    )
    next_step = { artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes", allowed_paths: [], addresses_criteria: [], success_check: "check" }

    question = described_class.ask!(decision:, next_step:, following_steps: [])

    refute_includes question.context, "a" * (described_class::TASK_LIMIT + 1)
    refute_includes question.context, "b" * (described_class::DIAGNOSIS_LIMIT + 1)
    assert_includes question.context, "a" * described_class::TASK_LIMIT
    assert_includes question.context, "b" * described_class::DIAGNOSIS_LIMIT
  end

  describe ".apply_pending_summaries!" do
    it "upgrades an open plan-approval question's text once its reporter completes, and patches the posted GitHub comment" do
      root = Dir.mktmpdir("plan-approval-apply-summary")
      workspace = Workspace.create!(name: "plan-approval-apply-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "plan-approval-apply-#{SecureRandom.hex(4)}", task: "Task", target_root: root,
        launcher_variant: "claude", status: "running", worktree_name: "apply-a1b2", branch_name: "workflow/apply-a1b2",
        github_issue_url: "https://github.com/example/repo/issues/9"
      )
      question = run.user_questions.create!(
        asked_by: "planner", scope: "run", priority: "blocking", status: "open",
        text: "Before any code is written...", context: "The plan.", tags: [ "plan-approval" ],
        github_comment_id: "555"
      )
      scope = Orchestrator::PlanApprovalQuestion.plan_summary_scope(question)
      Orchestrator::ArtifactStore.write(root, run.run_id, scope, "We're adding a way to attach files a worker can read.")
      run.workers.create!(
        worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter", reason: "Explain the plan.", scope:,
        status: "stopped", pid: 123, command: "claude", args: [], handoff_completed_at: 1.minute.ago,
        prompt_path: Rails.root.join("tmp/plan-summary-apply.prompt.txt").to_s,
        log_path: Rails.root.join("tmp/plan-summary-apply.log").to_s,
        last_message_path: Rails.root.join("tmp/plan-summary-apply.last.txt").to_s,
        env_path: Rails.root.join("tmp/plan-summary-apply.env").to_s
      )
      expect(Orchestrator::PullRequestResume).to receive(:patch_comment!).with(run, "555", a_string_including("We're adding a way to attach files"))

      Orchestrator::PlanApprovalQuestion.apply_pending_summaries!(run)

      question.reload
      expect(question.text).to start_with("We're adding a way to attach files a worker can read.")
      expect(question.tags).to include("summary_applied")
    end

    it "is a no-op while the reporter has not completed yet" do
      root = Dir.mktmpdir("plan-approval-apply-summary-pending")
      workspace = Workspace.create!(name: "plan-approval-apply-pending-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "plan-approval-apply-pending-#{SecureRandom.hex(4)}", task: "Task", target_root: root,
        launcher_variant: "claude", status: "running", worktree_name: "apply-pending-a1b2", branch_name: "workflow/apply-pending-a1b2"
      )
      question = run.user_questions.create!(
        asked_by: "planner", scope: "run", priority: "blocking", status: "open",
        text: "Before any code is written...", context: "The plan.", tags: [ "plan-approval" ]
      )
      expect(Orchestrator::PullRequestResume).not_to receive(:patch_comment!)

      Orchestrator::PlanApprovalQuestion.apply_pending_summaries!(run)

      expect(question.reload.text).to eq("Before any code is written...")
      expect(question.tags).not_to include("summary_applied")
    end
  end

  describe ".applicable?" do
    it "is false for a diagnosis step" do
      run = Workspace.create!(name: "plan-approval-applicable-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s).runs.create!(
        run_id: "plan-approval-applicable-#{SecureRandom.hex(4)}", task: "Task", target_root: Rails.root.to_s,
        launcher_variant: "claude", status: "running", worktree_name: "applicable-a1b2", branch_name: "workflow/applicable-a1b2"
      )

      expect(described_class.send(:applicable?, run:, next_step: { write_scope: "source_protected" })).to be(false)
    end

    scoped_changes_step = { write_scope: "scoped_changes", artifact: "x.md", mode: "implementation", allowed_paths: [], addresses_criteria: [], success_check: "x" }

    it "is true again after a plan-approval question was answered without being granted (an explain/revise round)" do
      run = Workspace.create!(name: "plan-approval-ungranted-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s).runs.create!(
        run_id: "plan-approval-ungranted-#{SecureRandom.hex(4)}", task: "Task", target_root: Rails.root.to_s,
        launcher_variant: "claude", status: "running", worktree_name: "ungranted-a1b2", branch_name: "workflow/ungranted-a1b2"
      )
      run.user_questions.create!(
        asked_by: "reply_received", scope: "run", priority: "blocking", status: "answered",
        text: "Approve?", tags: [ "plan-approval" ]
      )

      expect(described_class.send(:applicable?, run:, next_step: scoped_changes_step)).to be(true)
    end

    it "is permanently false once a plan-approval question carries the granted tag" do
      run = Workspace.create!(name: "plan-approval-granted-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s).runs.create!(
        run_id: "plan-approval-granted-#{SecureRandom.hex(4)}", task: "Task", target_root: Rails.root.to_s,
        launcher_variant: "claude", status: "running", worktree_name: "granted-a1b2", branch_name: "workflow/granted-a1b2"
      )
      run.user_questions.create!(
        asked_by: "reply_received", scope: "run", priority: "blocking", status: "answered",
        text: "Approve?", tags: [ "plan-approval", "granted" ]
      )

      expect(described_class.send(:applicable?, run:, next_step: scoped_changes_step)).to be(false)
    end
  end
end
