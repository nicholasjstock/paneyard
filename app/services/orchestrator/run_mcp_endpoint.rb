module Orchestrator
  # Mounted at /mcp/run. Authenticates a run session's private bearer
  # capability and hands the request to a transport scoped to that session.
  #
  # Stateless (McpTransport): the capability is the session's identity, so
  # the MCP layer has nothing of its own to remember. A transport is built
  # per request and dropped with it -- nothing to cache, reap or leak when the
  # run session ends, and a report_idle after hours of waiting on the
  # operator, or after a Paneyard restart, is answered like the first one.
  class RunMcpEndpoint
    def initialize
      @allowed_hosts = PaneyardAllowedHosts.extra
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      session = RunSession.authenticate_capability(token)
      return unauthorized unless session

      server = RunMcpServer.build(server_context: { run_session_id: session.id })
      McpTransport.build(server, allowed_hosts: @allowed_hosts).call(env)
    end

    private

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid run session capability"}' ] ]
    end
  end
end
