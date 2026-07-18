module Orchestrator
  class WorkspaceChatMcpEndpoint
    def initialize
      @transport = MCP::Server::Transports::StreamableHTTPTransport.new(WorkspaceChatMcpServer.build)
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      chat = WorkspaceChatCapability.authenticate(token)
      return [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid workspace chat capability"}' ] ] unless chat

      WorkspaceChatContext.chat = chat
      @transport.call(env)
    ensure
      WorkspaceChatContext.reset
    end
  end
end
