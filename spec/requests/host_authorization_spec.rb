require "rails_helper"

# DNS rebinding: a page the operator visits re-points its own name at
# 127.0.0.1 and becomes same-origin with this unauthenticated app, but its
# requests still carry its own name in Host. Production answers loopback
# names only (config/environments/production.rb). The test environment has
# its own config.hosts, so this checks production's allow-list through the
# same middleware in front of a stand-in app; bin/preflight checks that the
# real production boot rejects a foreign Host.
RSpec.describe "host authorization (DNS rebinding)", type: :request do
  def app_for(env)
    ActionDispatch::HostAuthorization.new(->(_) { [ 200, {}, [ "ok" ] ] }, PaneyardAllowedHosts.hosts(env))
  end

  def get_with_host(host, path: "/up", env: {})
    Rack::MockRequest.new(app_for(env)).get(path, "HTTP_HOST" => host)
  end

  it "rejects a foreign Host, on the UI and on the health check alike" do
    expect(get_with_host("rebound.example").status).to eq(403)
    expect(get_with_host("rebound.example:3000", path: "/").status).to eq(403)
    expect(get_with_host("localhost.rebound.example:3000").status).to eq(403)
  end

  it "answers loopback names, with or without a port" do
    [ "localhost", "localhost:3000", "127.0.0.1", "127.0.0.1:3000", "[::1]", "[::1]:3000" ].each do |host|
      expect(get_with_host(host).status).to eq(200), "expected #{host} to be allowed"
    end
  end

  it "answers the hosts named in PANEYARD_ALLOWED_HOSTS, and no others" do
    env = { "PANEYARD_ALLOWED_HOSTS" => " orchestrator.tailnet.ts.net, .proxy.internal ,[fd7a::1]" }

    expect(get_with_host("orchestrator.tailnet.ts.net", env:).status).to eq(200)
    expect(get_with_host("orchestrator.tailnet.ts.net:8443", env:).status).to eq(200)
    expect(get_with_host("app.proxy.internal", env:).status).to eq(200)
    expect(get_with_host("[fd7a::1]:3000", env:).status).to eq(200)
    expect(get_with_host("rebound.example", env:).status).to eq(403)
  end

  it "answers the host sessions are told to reach /mcp on (PANEYARD_RAILS_URL)" do
    env = { "PANEYARD_RAILS_URL" => "http://runner-host.lan:3000" }

    expect(PaneyardAllowedHosts.extra(env)).to eq([ "runner-host.lan" ])
    expect(get_with_host("runner-host.lan:3000", env:).status).to eq(200)
  end

  # The MCP gem's transport does its own Host/Origin check
  # (dns_rebinding_protection, on by default). Neither endpoint may turn it
  # off: /mcp/admin has no auth at all. The test environment's config.hosts
  # admits example.com, so a 403 here is the transport's own.
  describe "the MCP endpoints" do
    def post_mcp(endpoint, host, token: nil, origin: nil)
      headers = {
        "HTTP_HOST" => host, "CONTENT_TYPE" => "application/json",
        "HTTP_ACCEPT" => "application/json, text/event-stream",
        input: JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "0" } })
      }
      headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
      headers["HTTP_ORIGIN"] = origin if origin
      Rack::MockRequest.new(endpoint).post("/", headers)
    end

    def live_session_token
      token, digest = RunSession.issue_capability
      create_run(prefix: "mcp-host").run_sessions.create!(driver: "claude", status: "running", capability_token_digest: digest)
      token
    end

    it "keeps /mcp/admin's rebinding protection on" do
      endpoint = Orchestrator::AdminMcpEndpoint.new

      expect(post_mcp(endpoint, "127.0.0.1:3000").status).to eq(200)
      expect(post_mcp(endpoint, "example.com").status).to eq(403)
      expect(post_mcp(endpoint, "127.0.0.1:3000", origin: "http://rebound.example").status).to eq(403)
    end

    it "keeps /mcp/run's rebinding protection on" do
      endpoint = Orchestrator::RunMcpEndpoint.new
      token = live_session_token

      expect(post_mcp(endpoint, "127.0.0.1:3000", token:).status).to eq(200)
      expect(post_mcp(endpoint, "example.com", token:).status).to eq(403)
    end

    it "admits PANEYARD_ALLOWED_HOSTS there too, so a proxied UI and its MCP agree" do
      endpoint = with_env("PANEYARD_ALLOWED_HOSTS" => "orchestrator.tailnet.ts.net") { Orchestrator::AdminMcpEndpoint.new }

      expect(post_mcp(endpoint, "orchestrator.tailnet.ts.net").status).to eq(200)
      expect(post_mcp(endpoint, "example.com").status).to eq(403)
    end

    def with_env(values)
      saved = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
  end
end
