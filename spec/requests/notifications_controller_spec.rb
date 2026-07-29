require "rails_helper"

RSpec.describe "workspace notifications", type: :request do
  it "shows unread count, notification body, and the relevant pull request" do
    workspace = Workspace.create!(name: "notification-ui-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-ui-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", pull_request_url: "https://github.com/example/app/pull/13")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Which option should we use?", priority: "blocking")

    get workspace_notifications_path(workspace)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("1 unread notifications", question.text, run.pull_request_url)
    expect(response.body).to include("Mark read")
  end

  it "marks a notification read and removes it from the unread badge" do
    workspace = Workspace.create!(name: "notification-read-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-read-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Approve?", priority: "blocking")
    notification = Notification.find_by!(user_question: question)

    patch mark_read_workspace_notification_path(workspace, notification)

    expect(response).to redirect_to(workspace_notifications_path(workspace))
    expect(notification.reload).not_to be_unread
    follow_redirect!
    expect(response.body).to include("read")
    expect(response.body).not_to include("1 unread notifications")
  end
end
