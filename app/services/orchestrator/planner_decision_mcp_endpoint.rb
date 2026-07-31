module Orchestrator
  class PlannerDecisionMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      decision = PlannerDecisionCapability.authenticate(token)
      return unauthorized unless decision

      transport_for(decision).call(env)
    end

    private

    def transport_for(decision)
      @mutex.synchronize do
        @transports.delete_if { |id, _| !PlannerDecision.exists?(id:, status: PlannerDecision::ACTIVE_STATUSES) } if @transports.size >= 100
        @transports[decision.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          PlannerDecisionMcpServer.build(server_context: { decision_id: decision.decision_id }),
          enable_json_response: true
        )
      end
    end

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid planner decision capability"}' ] ]
    end
  end
end
