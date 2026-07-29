require "rails_helper"

RSpec.describe "workspace notifications", type: :system do
  it "renders the notification dropdown with an unread badge and blocking question link" do
    workspace = Workspace.create!(name: "notification-system-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-system-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", github_issue_url: "https://github.com/example/app/issues/7")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Choose a deployment target?", priority: "blocking")

    visit workspace_questions_path(workspace)

    expect(page).to have_text("Notifications")
    expect(page).to have_text("1")
    find("summary", text: "Notifications").click
    expect(page).to have_text(question.text)
    expect(page).to have_link("Blocking question needs your attention", href: run.github_issue_url)
  end
end
