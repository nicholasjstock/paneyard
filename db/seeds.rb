# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# A sandbox instance (bin/sandbox, bin/preflight) seeds its own scratch
# workspace with `bin/rails sandbox:seed` and must never register a real one.
return if Orchestrator::Sandbox.enabled?

# The one workspace every run was implicitly pointed at before workspaces
# existed as a real concept -- keeps pre-existing runs working the same
# way, and backfills their workspace_id for display/traceability.
default_root_path = ENV.fetch("WORKFLOW_TARGET_ROOT", "/Users/stockn/Source/simple-retail-planner/main")
default_workspace = Workspace.find_or_create_by!(root_path: default_root_path) do |workspace|
  workspace.name = "simple-retail-planner"
end
Run.where(target_root: default_workspace.root_path, workspace_id: nil).update_all(workspace_id: default_workspace.id)

# Demo fixtures for UI states that don't depend on any real model output --
# e.g. the current-runs drawer panel and its count badge just need Run rows
# in active statuses, spread across a few workspaces, with a range of
# title/worktree_name lengths to look at. Never seeded in production: that
# database holds this machine's one real history.
if Rails.env.development?
  demo_workspace = Workspace.find_or_create_by!(root_path: "/tmp/workflow-demo/simple-retail-planner") do |workspace|
    workspace.name = "demo: simple-retail-planner"
  end

  [
    { suffix: "short-title", status: "running", worktree_name: "add-cart-total", task: "Add cart total" },
    { suffix: "long-title", status: "running", worktree_name: "rework-checkout-flow-error-states",
      task: "Rework the checkout flow's error states so a failed payment shows the specific gateway " \
        "decline reason instead of a generic 'something went wrong' banner, matching what support " \
        "already sees in the gateway dashboard" },
    { suffix: "launching", status: "launching", worktree_name: "add-discount-codes", task: "Add discount codes" },
    { suffix: "stopping", status: "stopping", worktree_name: "fix-tax-rounding", task: "Fix tax rounding" },
    { suffix: "no-worktree-name", status: "running", worktree_name: nil, task: "Runs before worktree naming existed" }
  ].each do |attrs|
    run_id = "demo-#{attrs[:suffix]}"
    Run.find_or_create_by!(run_id: run_id) do |run|
      run.workspace = demo_workspace
      run.task = attrs[:task]
      run.target_root = File.join(demo_workspace.root_path, attrs[:suffix])
      run.launcher_variant = "claude"
      run.status = attrs[:status]
      run.worktree_name = attrs[:worktree_name]
    end
  end

  launch_artifact_run = Run.find_or_create_by!(run_id: "demo-launch-artifacts") do |run|
    run.workspace = demo_workspace
    run.task = "Review the uploaded launch artifacts"
    run.target_root = File.join(demo_workspace.root_path, "launch-artifacts")
    run.launcher_variant = "claude"
    run.status = "running"
    run.worktree_name = "review-launch-artifacts"
  end

  launch_artifacts = [
    { "name" => "requirements.txt", "source_run_id" => launch_artifact_run.run_id,
      "source_path" => "requirements.txt" },
    { "name" => "sample-data.json", "source_run_id" => launch_artifact_run.run_id,
      "source_path" => "sample-data.json" }
  ]
  launch_artifact_run.update!(launch_artifacts: launch_artifacts)
  seed_runner = Orchestrator::Runner.for(launch_artifact_run.workspace)
  seed_runner.store_attachment(source_root: launch_artifact_run.workspace.source_root, run_id: launch_artifact_run.run_id,
                               name: "requirements.txt", content: "Uploaded at launch\n- artifact manifest\n")
  seed_runner.store_attachment(source_root: launch_artifact_run.workspace.source_root, run_id: launch_artifact_run.run_id,
                               name: "sample-data.json", content: '{"source":"synthetic demo fixture","records":2}' + "\n")

  # Synthetic blockers keep the global notifications drawer visible across
  # workspaces without depending on a live planner or worker.
  notification_run = Run.find_by!(run_id: "demo-long-title")
  notification_question = UserQuestion.find_or_create_by!(question_id: "demo-blocking-question") do |question|
    question.run = notification_run
    question.asked_by = "planner"
    question.scope = "plan"
    question.text = "Which deployment target should this run use?"
    question.priority = "blocking"
    question.status = "open"
    question.github_comment_url = "https://github.com/example/simple-retail-planner/issues/42#issuecomment-123456789"
  end
  notification_question.update!(github_comment_url: "https://github.com/example/simple-retail-planner/issues/42#issuecomment-123456789")

  if notification_question.notification.nil?
    Notification.create!(
      workspace: demo_workspace,
      user_question: notification_question,
      kind: "blocking_question",
      title: Notification.review_title_for(notification_run),
      body: notification_question.text,
      link_url: notification_question.github_comment_url
    )
  end

  second_demo_workspace = Workspace.find_or_create_by!(root_path: "/tmp/workflow-demo/inventory-service") do |workspace|
    workspace.name = "demo: inventory-service"
  end
  second_notification_run = Run.find_or_create_by!(run_id: "demo-inventory-review") do |run|
    run.workspace = second_demo_workspace
    run.task = "Review inventory synchronization"
    run.target_root = File.join(second_demo_workspace.root_path, "review-inventory-sync")
    run.launcher_variant = "claude"
    run.status = "running"
    run.worktree_name = "review-inventory-sync"
  end
  second_notification_question = UserQuestion.find_or_create_by!(question_id: "demo-inventory-question") do |question|
    question.run = second_notification_run
    question.asked_by = "planner"
    question.scope = "plan"
    question.text = "Should inventory sync retry after a timeout?"
    question.priority = "blocking"
    question.status = "open"
  end

  if second_notification_question.notification.nil?
    Notification.create!(
      workspace: second_demo_workspace,
      user_question: second_notification_question,
      kind: "blocking_question",
      title: Notification.review_title_for(second_notification_run),
      body: second_notification_question.text,
      link_url: second_notification_run.conversation_url
    )
  end
end
