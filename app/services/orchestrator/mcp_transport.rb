module Orchestrator
  # The Streamable HTTP transport both MCP endpoints use: stateless.
  #
  # A stateful transport keeps each client's MCP session in this process's
  # memory, so it is lost on every restart (the only way new code goes live)
  # and, by the mcp gem's default, after 30 idle minutes -- shorter than a
  # run session often waits on the operator. The client's next call then
  # gets 404 "Session not found" and depends on the client re-initializing.
  # Nothing here needs that session: every tool reads only its server's fixed
  # server_context (the run session id, or nothing for /mcp/admin), and no
  # tool sends a notification or a request back to the client. Stateless, each
  # POST stands alone, an Mcp-Session-Id left over from before is ignored, and
  # there is no session store to grow, reap or flood -- which also retires the
  # memory concern an idle timeout and max_sessions exist for on the
  # unauthenticated /mcp/admin (SECURITY.md).
  #
  # subscriptions/listen is off: nothing ever notifies, and it would only hold
  # an SSE connection (and a keepalive thread) open for nothing.
  module McpTransport
    module_function

    def build(server, allowed_hosts: PaneyardAllowedHosts.extra)
      MCP::Server::Transports::StreamableHTTPTransport.new(
        server, stateless: true, serve_subscriptions_listen: false, allowed_hosts:
      )
    end
  end
end
