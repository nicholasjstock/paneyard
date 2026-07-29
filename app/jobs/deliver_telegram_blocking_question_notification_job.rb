class DeliverTelegramBlockingQuestionNotificationJob < ApplicationJob
  queue_as :default

  def perform(question_id)
    return unless Telegram::Configuration.polling_configured?

    question = UserQuestion.includes(:run).find_by(id: question_id)
    return unless question&.priority == "blocking"

    text = message_text(question)
    conversations.find_each do |conversation|
      Telegram::Client.new.send_message(chat_id: conversation.telegram_chat_id, text: text)
    end
  end

  private

  def conversations
    TelegramConversation.where(telegram_user_id: Telegram::Configuration.allowed_user_ids)
  end

  def message_text(question)
    link = question.run&.conversation_url.presence || question.github_comment_url
    [
      "Blocking question needs your attention:",
      question.text,
      ("GitHub: #{link}" if link.present?)
    ].compact.join("\n\n")
  end
end
