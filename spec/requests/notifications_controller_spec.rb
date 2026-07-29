require "rails_helper"

RSpec.describe "workspace notifications", type: :request do
  it "shows the global stream without a selected workspace" do
    workspace = Workspace.create!(name: "notification-root-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-root-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Root question", priority: "blocking")

    get notifications_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(question.text, "Mark read")
    expect(response.body).to include(mark_read_notification_path(Notification.find_by!(user_question: question)))
  end

  it "marks a notification read from the global route" do
    workspace = Workspace.create!(name: "notification-root-read-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-root-read-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Root approve?", priority: "blocking")
    notification = Notification.find_by!(user_question: question)

    patch mark_read_notification_path(notification)

    expect(response).to redirect_to(notifications_path)
    expect(notification.reload).not_to be_unread
  end

  it "marks every notification unread when the global drawer closes" do
    workspace = Workspace.create!(name: "notification-close-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-close-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    first_question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "First close?", priority: "blocking")
    second_run = Run.create!(run_id: SecureRandom.uuid, task: "Need another review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    second_question = second_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Second close?", priority: "blocking")
    read_run = Run.create!(run_id: SecureRandom.uuid, task: "Already reviewed", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")
    read_question = read_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Already closed?", priority: "blocking")
    first_notification = Notification.find_by!(user_question: first_question)
    second_notification = Notification.find_by!(user_question: second_question)
    already_read = Notification.find_by!(user_question: read_question)
    already_read.mark_read!

    patch mark_all_read_notifications_path

    expect(response).to have_http_status(:no_content)
    expect(first_notification.reload).not_to be_unread
    expect(second_notification.reload).not_to be_unread
    expect(already_read.reload).not_to be_unread
  end

  it "marks a notification read when opening its target" do
    workspace = Workspace.create!(name: "notification-open-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-open-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", pull_request_url: "https://github.com/example/app/pull/14")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Open target?", priority: "blocking")
    notification = Notification.find_by!(user_question: question)

    get open_notification_path(notification)

    expect(response).to redirect_to(run.pull_request_url)
    expect(notification.reload).not_to be_unread
  end

  it "shows unread count, notification body, and the relevant pull request" do
    workspace = Workspace.create!(name: "notification-ui-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-ui-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Need review", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", pull_request_url: "https://github.com/example/app/pull/13")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Which option should we use?", priority: "blocking")

    get workspace_notifications_path(workspace)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("1 unread notifications", question.text, open_notification_path(Notification.find_by!(user_question: question)))
    expect(response.body).to include("Mark read")
    expect(response.body).to include("target=\"_blank\"")
    expect(response.body).to include("rel=\"noopener\"")
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

  it "shows notifications from every workspace in the global stream" do
    first_workspace = Workspace.create!(name: "notification-global-a-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-global-a-#{SecureRandom.hex(4)}")
    second_workspace = Workspace.create!(name: "notification-global-b-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-global-b-#{SecureRandom.hex(4)}")
    first_run = Run.create!(run_id: SecureRandom.uuid, task: "First review", workspace: first_workspace, target_root: first_workspace.root_path, launcher_variant: "codex", status: "running")
    second_run = Run.create!(run_id: SecureRandom.uuid, task: "Second review", workspace: second_workspace, target_root: second_workspace.root_path, launcher_variant: "codex", status: "running")
    first_question = first_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "First question", priority: "blocking")
    second_question = second_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Second question", priority: "blocking")

    get workspace_notifications_path(second_workspace)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(first_question.text, second_question.text, "2 unread notifications")
  end

  it "marks a notification from another workspace read without changing other rows" do
    first_workspace = Workspace.create!(name: "notification-global-read-a-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-global-read-a-#{SecureRandom.hex(4)}")
    second_workspace = Workspace.create!(name: "notification-global-read-b-#{SecureRandom.hex(4)}", root_path: "/tmp/notification-global-read-b-#{SecureRandom.hex(4)}")
    first_run = Run.create!(run_id: SecureRandom.uuid, task: "First review", workspace: first_workspace, target_root: first_workspace.root_path, launcher_variant: "codex", status: "running")
    second_run = Run.create!(run_id: SecureRandom.uuid, task: "Second review", workspace: second_workspace, target_root: second_workspace.root_path, launcher_variant: "codex", status: "running")
    first_question = first_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "First question", priority: "blocking")
    second_question = second_run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Second question", priority: "blocking")
    first_notification = Notification.find_by!(user_question: first_question)
    second_notification = Notification.find_by!(user_question: second_question)

    patch mark_read_workspace_notification_path(second_workspace, first_notification)

    expect(response).to redirect_to(workspace_notifications_path(second_workspace))
    expect(first_notification.reload).not_to be_unread
    expect(second_notification.reload).to be_unread
  end
end
