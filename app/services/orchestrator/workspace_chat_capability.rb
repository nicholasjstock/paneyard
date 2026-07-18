module Orchestrator
  module WorkspaceChatCapability
    module_function

    def issue(chat)
      verifier.generate({ chat_id: chat.id }, expires_in: 2.hours)
    end

    def authenticate(token)
      payload = verifier.verified(token)
      chat_id = payload && (payload[:chat_id] || payload["chat_id"])
      WorkspaceChat.find_by(id: chat_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def verifier
      Rails.application.message_verifier("workspace-chat-capability")
    end
    private_class_method :verifier
  end
end
