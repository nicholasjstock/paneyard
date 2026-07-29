require "rails_helper"

RSpec.describe "global notifications", type: :system do
  def create_notification_fixture
    workspace = Workspace.create!(name: "notification-system-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-system-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", github_issue_url: "https://github.com/example/app/issues/7")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Choose a deployment target?", priority: "blocking")
    [ workspace, run, question ]
  end

  it "renders the compact global launcher and notification preview" do
    workspace, run, question = create_notification_fixture

    visit workspace_questions_path(workspace)

    expect(page).to have_text("Notifications")
    expect(page).to have_text("1")
    expect(page).to have_css("button[aria-label='Open notifications'][data-action='notification-drawer#open']")
    expect(page).to have_css("aside[aria-label='Global notifications'][aria-hidden='true']")
    expect(page).to have_css("button[aria-label='Open notifications'][aria-expanded='false']")
    expect(page).to have_text(question.text)
    expect(page).to have_link("Blocking question needs your attention", href: run.github_issue_url)
  end

  it "opens and closes the notification drawer", js: true do
    workspace, = create_notification_fixture

    visit workspace_questions_path(workspace)

    click_button "Open notifications"

    expect(page).to have_css("aside[aria-label='Global notifications'][aria-hidden='false']")
    expect(page).to have_css("body.notification-open .notification-drawer")
    expect(page).to have_css("button[aria-label='Open notifications'][aria-expanded='true']")
    expect(page).to have_text("Across every workspace")
    active_label = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      window.setTimeout(() => done(document.activeElement.getAttribute("aria-label")), 250)
    JS
    expect(active_label).to eq("Global notifications")

    click_button "Close notifications"

    expect(page).to have_css("aside[aria-label='Global notifications'][aria-hidden='true']")
  end
end
