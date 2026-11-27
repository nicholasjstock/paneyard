require "rails_helper"

RSpec.describe Orchestrator::Runner::Endpoint do
  let(:runner) { instance_double(Orchestrator::Runner::Local, ping: { "hostname" => "mac" }) }
  let(:app) { Rack::MockRequest.new(described_class.new(runner:)) }

  def call(body, headers: { "CONTENT_TYPE" => "application/json" }, path: "/call", method: :post)
    response = app.request(method.to_s.upcase, path, headers.merge(input: body.is_a?(String) ? body : JSON.generate(body)))
    [ response.status, JSON.parse(response.body) ]
  end

  it "dispatches an allowed method and answers with its result" do
    expect(call({ "method" => "ping" })).to eq([ 200, { "ok" => true, "result" => { "hostname" => "mac" } } ])
  end

  it "answers nothing but the runner interface" do
    status, body = call({ "method" => "instance_eval", "args" => [ "1" ] })

    expect(status).to eq(400)
    expect(body.dig("error", "message")).to eq('"instance_eval" is not a runner method')
    expect(call({ "method" => "runtime_root" }).first).to eq(400)
    expect(call("not json").first).to eq(400)
    expect(call([ "ping" ]).first).to eq(400)
  end

  # A page in the operator's browser can aim a form POST at 127.0.0.1, which
  # config.hosts lets through; it cannot send application/json without a
  # preflight, and always says where it came from.
  it "refuses what a browser could send cross-origin" do
    expect(call({ "method" => "ping" }, headers: { "CONTENT_TYPE" => "text/plain" }).first).to eq(415)
    expect(call({ "method" => "ping" }, headers: { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://evil.example" }).first).to eq(403)
    expect(call({ "method" => "ping" }, method: :get).first).to eq(405)
    expect(call({ "method" => "ping" }, path: "/other").first).to eq(404)
    expect(runner).not_to have_received(:ping)
  end
end

RSpec.describe "the orchestrator's routes", type: :request do
  it "serves no runner endpoint: only a runner-only process (bin/runner) does" do
    host! "127.0.0.1"
    post "/runner/call", params: JSON.generate(method: "ping"), headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:not_found)
  end
end
