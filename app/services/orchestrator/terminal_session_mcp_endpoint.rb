module Orchestrator
  class TerminalSessionMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      session = TerminalSessionCapability.authenticate(token)
      return unauthorized unless session

      transport_for(session).call(env)
    end

    private

    def transport_for(session)
      @mutex.synchronize do
        @transports[session.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          TerminalSessionMcpServer.build(server_context: { terminal_session_id: session.id })
        )
      end
    end

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid terminal session capability"}' ] ]
    end
  end
end
