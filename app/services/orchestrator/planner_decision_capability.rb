module Orchestrator
  module PlannerDecisionCapability
    module_function

    def issue(decision)
      verifier.generate({ decision_id: decision.decision_id }, expires_in: 10.minutes)
    end

    def authenticate(token)
      payload = verifier.verified(token)
      decision_id = payload && (payload[:decision_id] || payload["decision_id"])
      PlannerDecision.find_by(decision_id: decision_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def verifier
      Rails.application.message_verifier("planner-decision-capability")
    end
    private_class_method :verifier
  end
end
