module Orchestrator
  module TerminalSessionCapability
    module_function

    def issue(session)
      verifier.generate({ terminal_session_id: session.id }, expires_in: 2.hours)
    end

    def authenticate(token)
      payload = verifier.verified(token)
      session_id = payload && (payload[:terminal_session_id] || payload["terminal_session_id"])
      TerminalSession.find_by(id: session_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def verifier
      Rails.application.message_verifier("terminal-session-capability")
    end
    private_class_method :verifier
  end
end
