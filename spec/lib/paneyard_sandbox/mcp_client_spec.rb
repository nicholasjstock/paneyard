require "spec_helper"
require "json"
require_relative "../../../lib/paneyard_sandbox/mcp_client"

# The HTTP side is a scripted stand-in that answers like the real server: a
# fresh session id on initialize, and 404 "Session not found" for any id it
# does not know -- which is what a Paneyard restart does to a popup that
# connected before it.
RSpec.describe PaneyardSandbox::McpClient do
  subject(:client) { described_class.new("http://127.0.0.1:7999/mcp/admin") }

  let(:sent) { [] }
  let(:known) { [] }
  let(:issue) { %w[s1 s2] }
  let(:honour_new_sessions) { true }

  def json_response(klass, body, session: nil)
    klass.new("1.1", klass == Net::HTTPOK ? "200" : "404", "").tap do |response|
      response["content-type"] = "application/json"
      response["mcp-session-id"] = session if session
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, JSON.generate(body))
    end
  end

  def answer(request)
    body = JSON.parse(request.body)
    sent << [ body["method"], request["Mcp-Session-Id"] ]
    if body["method"] == "initialize"
      id = issue.shift
      known << id if honour_new_sessions || id == "s1"
      return json_response(Net::HTTPOK, { jsonrpc: "2.0", id: body["id"], result: {} }, session: id)
    end
    unless known.include?(request["Mcp-Session-Id"])
      return json_response(Net::HTTPNotFound, { jsonrpc: "2.0", id: nil, error: { code: -32600, message: "Session not found" } })
    end
    return json_response(Net::HTTPOK, {}) unless body["id"]

    json_response(Net::HTTPOK, { jsonrpc: "2.0", id: body["id"], result: { structuredContent: { "workspaces" => [] }, content: [] } })
  end

  before do
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) { |request| answer(request) }
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  it "renews a session the server has forgotten and retries the call once" do
    client.call_tool("list_workspaces")
    known.clear # Paneyard restarted

    expect(client.call_tool("list_workspaces")).to eq("workspaces" => [])
    expect(sent.last(4)).to eq([
      [ "tools/call", "s1" ], [ "initialize", nil ], [ "notifications/initialized", "s2" ], [ "tools/call", "s2" ]
    ])
  end

  it "sends request metadata alongside tool arguments" do
    allow(client).to receive(:post).and_wrap_original do |original, body|
      if body[:method] == "tools/call"
        expect(body[:params]).to eq(name: "job_finished", arguments: { summary: "Merged; end requested" },
          _meta: { progressToken: "finish" })
      end
      original.call(body)
    end

    client.call_tool("job_finished", meta: { progressToken: "finish" }, summary: "Merged; end requested")
    expect(sent.last.first).to eq("tools/call")
  end

  context "when the renewed session is refused as well" do
    let(:honour_new_sessions) { false }

    it "gives up rather than looping" do
      client.call_tool("list_workspaces")
      known.clear

      expect { client.call_tool("list_workspaces") }.to raise_error(PaneyardSandbox::McpClient::SessionExpired)
      expect(sent.count { |method, _| method == "initialize" }).to eq(2)
    end
  end

  # This app's own endpoints are stateless: no Mcp-Session-Id comes back,
  # and the client must not mistake that for "not initialized yet".
  context "against a stateless server" do
    let(:issue) { [ nil ] }

    before { known << nil }

    it "initializes once and then just calls" do
      2.times { client.call_tool("list_workspaces") }

      expect(sent.map(&:first)).to eq(%w[initialize notifications/initialized tools/call tools/call])
    end
  end
end
