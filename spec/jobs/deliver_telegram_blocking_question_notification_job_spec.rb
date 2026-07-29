require "rails_helper"

RSpec.describe DeliverTelegramBlockingQuestionNotificationJob do
  let(:client) { instance_double(Telegram::Client, send_message: true) }

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(Telegram::Configuration).to receive(:allowed_user_ids).and_return([ "42" ])
    allow(Telegram::Configuration).to receive(:polling_configured?).and_return(true)
  end

  it "sends the blocking question and its pull request link to the configured administrator" do
    workspace = Workspace.create!(name: "Telegram question #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(run_id: SecureRandom.uuid, task: "Wait for guidance", workspace:, target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", pull_request_url: "https://github.com/example/app/pull/12")
    TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Approve this plan?", priority: "blocking")

    described_class.perform_now(question.id)

    expect(client).to have_received(:send_message).with(
      chat_id: "123",
      text: include("Approve this plan?", "https://github.com/example/app/pull/12")
    )
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end

  it "uses the run issue link when no pull request exists" do
    workspace = Workspace.create!(name: "Telegram issue #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(run_id: SecureRandom.uuid, task: "Wait for guidance", workspace:, target_root: workspace.root_path,
      launcher_variant: "codex", status: "running", github_issue_url: "https://github.com/example/app/issues/7")
    TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42")
    question = run.user_questions.create!(asked_by: "planner", scope: "plan", text: "Choose a setting?", priority: "blocking")

    described_class.perform_now(question.id)

    expect(client).to have_received(:send_message).with(
      chat_id: "123",
      text: include("Choose a setting?", "https://github.com/example/app/issues/7")
    )
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end
end
