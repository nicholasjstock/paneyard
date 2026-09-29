require "tmpdir"

# Runs a FakeHerdr::Server on a throwaway socket for the duration of an
# example and points Orchestrator::Runner::Herdr at it -- the real client, the real
# wire protocol, and real agent processes, but never the operator's herdr.
#
#   it "...", :fake_herdr do
#     fake_herdr.requests_for("workspace.create")
#   end
#
# FAKE_AGENT_MODE for the agents it launches defaults to "manual" (the spec
# reports on the session's behalf, over /mcp/run, when it wants to); set
# `fake_agent_mode:` to change it, or `fake_agent_command:` to launch
# something else entirely (e.g. a CLI that dies on startup).
module FakeHerdrHelper
  def fake_herdr
    @fake_herdr
  end
end

RSpec.configure do |config|
  config.include FakeHerdrHelper

  config.around(:each, :fake_herdr) do |example|
    dir = Dir.mktmpdir("fh")
    mode = example.metadata[:fake_agent_mode] || "manual"
    @fake_herdr = FakeHerdr::Server.new(
      socket_path: File.join(dir, "herdr.sock"), agent_env: { "FAKE_AGENT_MODE" => mode, "FAKE_AGENT_WORK_SECONDS" => "0.6" },
      agent_command: example.metadata[:fake_agent_command]
    ).start
    original = ENV["HERDR_SOCKET_PATH"]
    ENV["HERDR_SOCKET_PATH"] = @fake_herdr.socket_path
    example.run
  ensure
    ENV["HERDR_SOCKET_PATH"] = original
    @fake_herdr&.stop
    FileUtils.rm_rf(dir) if dir
  end
end
