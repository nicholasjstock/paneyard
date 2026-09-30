module Orchestrator
  # Mounted at /mcp/run. Authenticates a run session's private bearer
  # capability and hands it a transport scoped to that session.
  class RunMcpEndpoint
    MAX_CACHED_TRANSPORTS = 100

    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      session = RunSession.authenticate_capability(token)
      return unauthorized unless session

      transport_for(session).call(env)
    end

    private

    def transport_for(session)
      @mutex.synchronize do
        if @transports.size >= MAX_CACHED_TRANSPORTS
          live_ids = RunSession.live.where(id: @transports.keys).pluck(:id).to_set
          @transports.delete_if { |id, _| !live_ids.include?(id) }
        end
        @transports[session.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          RunMcpServer.build(server_context: { run_session_id: session.id }),
          allowed_hosts: PaneyardAllowedHosts.extra
        )
      end
    end

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid run session capability"}' ] ]
    end
  end
end
