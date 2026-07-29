require "rails_helper"

RSpec.describe Notification, type: :model do
  it "is created durably for a blocking question and links to its run conversation" do
    workspace = Workspace.create!(name: "notifications-#{SecureRandom.hex(4)}", root_path: "/tmp/notifications-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Wait for guidance", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running", pull_request_url: "https://github.com/example/app/pull/12")

    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Approve this plan?", priority: "blocking")

    notification = Notification.find_by!(user_question: question)
    expect(notification).to have_attributes(kind: "blocking_question", title: "Wait for guidance is ready for review", body: question.text, read_at: nil)
    expect(notification.target_url).to eq(run.pull_request_url)
  end

  it "queues Telegram delivery for a blocking question" do
    workspace = Workspace.create!(name: "notifications-#{SecureRandom.hex(4)}", root_path: "/tmp/notifications-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Wait for guidance", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")

    expect {
      run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Approve this plan?", priority: "blocking")
    }.to have_enqueued_job(DeliverTelegramBlockingQuestionNotificationJob)
  end

  it "does not create notifications for advisory questions" do
    workspace = Workspace.create!(name: "notifications-#{SecureRandom.hex(4)}", root_path: "/tmp/notifications-#{SecureRandom.hex(4)}")
    run = Run.create!(run_id: SecureRandom.uuid, task: "Inform operator", workspace:, target_root: workspace.root_path, launcher_variant: "codex", status: "running")

    expect { run.user_questions.create!(asked_by: "worker", scope: "log", text: "FYI", priority: "advisory") }.not_to change(Notification, :count)
  end
end
