module Orchestrator
  class PlannerDecisionMcpEndpoint
    def initialize
      @transport = MCP::Server::Transports::StreamableHTTPTransport.new(PlannerDecisionMcpServer.build)
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      decision = PlannerDecisionCapability.authenticate(token)
      return [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid planner decision capability"}' ] ] unless decision

      PlannerDecisionContext.decision = decision
      @transport.call(env)
    ensure
      PlannerDecisionContext.reset
    end
  end
end
