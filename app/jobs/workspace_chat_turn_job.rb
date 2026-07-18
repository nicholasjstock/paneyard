class WorkspaceChatTurnJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = WorkspaceChatMessage.find(message_id)
    chat = message.workspace_chat
    return unless message.status == "queued"

    chat.update!(status: "processing", last_error: nil)
    message.update!(status: "processing")
    result = Orchestrator::WorkspaceChatRunner.call(chat:, message: message.content)
    WorkspaceChat.transaction do
      chat.update!(session_id: result[:session_id].presence || chat.session_id, status: "idle")
      message.update!(status: "completed")
      chat.messages.create!(role: "assistant", content: result[:response], status: "completed", usage: result[:usage])
    end
  rescue => error
    message&.update!(status: "failed")
    chat&.update!(status: "failed", last_error: error.message)
    raise
  end
end
