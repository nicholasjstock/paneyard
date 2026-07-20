module Orchestrator
  class WorkspaceChatMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      chat = WorkspaceChatCapability.authenticate(token)
      return unauthorized unless chat

      transport_for(chat).call(env)
    end

    private

    def transport_for(chat)
      @mutex.synchronize do
        @transports[chat.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          WorkspaceChatMcpServer.build(server_context: { chat_id: chat.id })
        )
      end
    end

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid workspace chat capability"}' ] ]
    end
  end
end
