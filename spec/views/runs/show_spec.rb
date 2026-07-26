require "rails_helper"

RSpec.describe "runs/show", type: :view do
  module CurrentWorkspaceHelper
    def current_workspace
      @workspace
    end
  end

  def create_workspace
    suffix = SecureRandom.hex(4)
    Workspace.create!(
      name: "view-spec-#{suffix}",
      root_path: "/tmp/view-spec-#{suffix}",
      protected_path_patterns: []
    )
  end

  def create_run(workspace:, suffix:, task:)
    Run.create!(
      run_id: "demo-#{suffix}-#{SecureRandom.hex(4)}",
      task: task,
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )
  end

  before(:each) do
    @workspace = create_workspace
    # Make current_workspace available to the view
    view.singleton_class.send(:include, CurrentWorkspaceHelper)
  end

  it "renders run-level blocking questions in the workflow tree" do
    run = create_run(workspace: @workspace, suffix: "qa-tree", task: "Test Q&A tree rendering")
    run.user_questions.create!(
      asked_by: "worker",
      scope: nil,
      text: "Which direction should we proceed?",
      priority: "blocking",
      status: "open"
    )

    # Create an acceptance criterion so the workflow tree section renders
    criterion = run.acceptance_criteria.create!(key: "test-criterion", content: "Test criterion")

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, {})
    assign(:planner_decisions, [])
    assign(:all_user_questions, run.user_questions.where(status: "open").order(:asked_at).to_a)
    assign(:blocking_questions, run.user_questions.where(priority: "blocking").to_a)
    assign(:worker_activities, [])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    render

    expect(rendered).to include("Question")
    expect(rendered).to include("Which direction should we proceed?")
    expect(rendered).to include("blocking")
    expect(rendered).to include("workflow-question-node")
  end

  it "renders workflow tree without error when no blocking questions exist" do
    run = create_run(workspace: @workspace, suffix: "qa-no-questions", task: "Test tree without questions")

    # Create an acceptance criterion so the workflow tree section renders
    criterion = run.acceptance_criteria.create!(key: "test-criterion", content: "Test criterion")

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, {})
    assign(:planner_decisions, [])
    assign(:all_user_questions, [])
    assign(:blocking_questions, [])
    assign(:worker_activities, [])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    expect { render }.not_to raise_error
    expect(rendered).to include("No acceptance criteria established yet.").or include("Workflow tree")
  end

  it "renders criterion-scoped questions under their matching criterion" do
    run = create_run(workspace: @workspace, suffix: "qa-criterion-scope", task: "Test criterion scope filtering")

    # Create a criterion and a question scoped to it
    criterion = run.acceptance_criteria.create!(key: "auth-endpoint", content: "Implement auth endpoint")
    run.user_questions.create!(
      asked_by: "worker",
      scope: "auth-endpoint",
      text: "Should we support OAuth?",
      priority: "advisory",
      status: "open"
    )

    # Create a run-level question that should appear at root
    run.user_questions.create!(
      asked_by: "worker",
      scope: nil,
      text: "Should we deploy to staging?",
      priority: "blocking",
      status: "open"
    )

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, {})
    assign(:planner_decisions, [])
    assign(:all_user_questions, run.user_questions.where(status: "open").order(:asked_at).to_a)
    assign(:blocking_questions, run.user_questions.where(priority: "blocking").to_a)
    assign(:worker_activities, [])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    render

    # Check that both questions are rendered
    expect(rendered).to include("Should we support OAuth?")
    expect(rendered).to include("Should we deploy to staging?")
  end

  it "indicates worker-scoped questions with a questions badge" do
    run = create_run(workspace: @workspace, suffix: "qa-worker-scope", task: "Test worker scope filtering")

    # Create a criterion
    criterion = run.acceptance_criteria.create!(key: "test-work", content: "Test work")

    # Create a question scoped to a worker
    run.user_questions.create!(
      asked_by: "orchestrator",
      scope: "test-worker",
      text: "Need clarification on requirements",
      priority: "advisory",
      status: "open"
    )

    # Mock a worker with a question
    mock_worker = double("Worker", worker_id: "worker-123", nickname: "test-worker", role: "implementation", scope: "test-work", status: "running", model: nil, pid: 12345, started_at: Time.current, stopped_at: nil, stop_reason: nil, agent_turn_count: nil, input_tokens: nil, output_tokens: nil, total_cost_usd: nil, reason: "Testing", prompt_path: nil, log_path: nil, last_message_path: nil, env_path: nil, command: nil)

    activity = {
      worker: mock_worker,
      status_label: "running",
      display_status: "running",
      last_activity_at: Time.current,
      chaperone_review: nil,
      assignment_text: "Test assignment",
      assignment_context: nil,
      output_preview: nil,
      output_source: nil
    }

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, { criterion.id => [ activity ] })
    assign(:planner_decisions, [])
    assign(:all_user_questions, run.user_questions.where(status: "open").order(:asked_at).to_a)
    assign(:blocking_questions, [])
    assign(:worker_activities, [ activity ])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [ activity ])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    render

    # Check that the worker's name appears
    expect(rendered).to include("test-worker")
    # Check that the "questions" badge appears on the worker
    expect(rendered).to include("questions")
  end

  it "displays state badges for blocking questions with different statuses" do
    run = create_run(workspace: @workspace, suffix: "qa-state-badges", task: "Test question state badges")

    # Create criterion
    criterion = run.acceptance_criteria.create!(key: "test-criterion", content: "Test criterion")

    # Create blocking questions with different statuses
    run.user_questions.create!(
      asked_by: "worker",
      scope: nil,
      text: "Is this the right approach?",
      priority: "blocking",
      status: "open"
    )

    run.user_questions.create!(
      asked_by: "worker",
      scope: nil,
      text: "Should we use this pattern?",
      priority: "blocking",
      status: "answered"
    )

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, {})
    assign(:planner_decisions, [])
    assign(:all_user_questions, run.user_questions.order(:asked_at).to_a)
    assign(:blocking_questions, run.user_questions.where(priority: "blocking").to_a)
    assign(:worker_activities, [])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    render

    # Verify both state badges are rendered (each question should have an "open" or "answered" badge)
    expect(rendered).to include("open")
    expect(rendered).to include("answered")
    # Verify both question texts are present
    expect(rendered).to include("Is this the right approach?")
    expect(rendered).to include("Should we use this pattern?")
  end

  it "renders question details in expandable panels" do
    run = create_run(workspace: @workspace, suffix: "qa-expandable", task: "Test expandable question panels")

    # Create criterion
    criterion = run.acceptance_criteria.create!(key: "auth-flow", content: "Implement auth flow")

    # Create a blocking question with context and links
    run.user_questions.create!(
      asked_by: "worker",
      scope: nil,
      text: "Should we use JWT or sessions?",
      context: "Need to decide on auth mechanism",
      priority: "blocking",
      status: "open"
    )

    assign(:run, run)
    assign(:planner_activities, [])
    assign(:acceptance_criteria, [ criterion ])
    assign(:criterion_worker_groups, {})
    assign(:planner_decisions, [])
    assign(:all_user_questions, run.user_questions.order(:asked_at).to_a)
    assign(:blocking_questions, run.user_questions.where(priority: "blocking").to_a)
    assign(:worker_activities, [])
    assign(:nested_planner_ids, [])
    assign(:spawn_requests, [])
    assign(:chaperone_reviews, [])
    assign(:active_workers, [])
    assign(:timeline_events, [])
    assign(:artifacts, [])
    assign(:usage_summary, { total_cost_usd: 0, input_tokens: 0, output_tokens: 0, models: {} })
    assign(:activity_feed, [])
    assign(:run_now, {
      state: "Test state",
      detail: "Test detail",
      status_class: "test",
      badge_label: "test",
      why: "test",
      next: "test",
      operator_action: "test",
      operator_action_required: false,
      latest_activity_at: Time.current
    })
    assign(:run_commands, [])

    render

    # Verify question node structure
    expect(rendered).to include("workflow-question-node")
    expect(rendered).to include("Should we use JWT or sessions?")
    expect(rendered).to include("Need to decide on auth mechanism")
    # Verify the card content exists
    expect(rendered).to include("mini-card")
    expect(rendered).to include("question-card")
  end
end
