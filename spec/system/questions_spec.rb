require "rails_helper"

RSpec.describe "workspace questions", type: :system do
  it "lists only questions for the selected workspace" do
    workspace, run = create_workspace_with_run("alpha")
    question = run.user_questions.create!(
      asked_by: "planner",
      scope: "workflow-plan.md",
      text: "Need product guidance?",
      priority: "blocking"
    )

    other_workspace, other_run = create_workspace_with_run("beta")
    other_run.user_questions.create!(
      asked_by: "planner",
      scope: "workflow-plan.md",
      text: "Should not appear here",
      priority: "advisory"
    )

    visit workspace_questions_path(workspace)

    expect(page).to have_text(question.text)
    expect(page).to have_no_text("Should not appear here")
  end

  it "directs open questions to GitHub rather than offering a local answer form" do
    workspace, run = create_workspace_with_run("alpha")
    question = run.user_questions.create!(
      asked_by: "planner",
      scope: "workflow-plan.md",
      text: "Need product guidance?",
      priority: "blocking"
    )

    question.update!(github_comment_url: "https://github.com/example/repo/pull/1#issuecomment-1")

    visit workspace_questions_path(workspace)

    expect(page).to have_link("Open GitHub question", href: question.github_comment_url)
    expect(page).to have_text("Question #{question.question_id}: <your answer>")
    expect(page).to have_no_field("answer_text")
  end

  it "shows the empty state when a workspace has no questions" do
    workspace, = create_workspace_with_run("alpha")

    visit workspace_questions_path(workspace)

    expect(page).to have_text("No questions recorded.")
  end

  it "updates the questions index live when a question is created", :js do
    workspace, run = create_workspace_with_run("alpha")

    visit workspace_questions_path(workspace)
    expect(page).to have_text("No questions recorded.")

    creator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        run.user_questions.create!(
          asked_by: "planner",
          scope: "workflow-plan.md",
          text: "Need a live answer?",
          priority: "blocking"
        )
      end
    end

    expect(page).to have_text("Need a live answer?")
    expect(page).to have_text(run.run_id)

    creator.join
  end

  def create_workspace_with_run(prefix)
    suffix = "#{prefix}-#{SecureRandom.hex(4)}"
    workspace = Workspace.create!(name: "planner-#{suffix}", root_path: "/tmp/planner-#{suffix}")
    run = Run.create!(
      run_id: "demo-question-#{suffix}",
      task: "Inspect questions in #{prefix}",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )
    [ workspace, run ]
  end
end
