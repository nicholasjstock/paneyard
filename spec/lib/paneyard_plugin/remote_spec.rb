require "spec_helper"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::Remote do
  let(:remote) { described_class.new("http://server.example:7263", "/Users/me=/home/me, /Volumes/code/=/srv/code") }

  describe ".from" do
    it "is nil unless PANEYARD_REMOTE_URL is set" do
      expect(described_class.from({})).to be_nil
      expect(described_class.from("PANEYARD_REMOTE_URL" => " ")).to be_nil
    end

    it "takes the URL without a trailing slash" do
      expect(described_class.from("PANEYARD_REMOTE_URL" => "http://server.example:7263/").url).to eq("http://server.example:7263")
    end
  end

  it "names the host it runs on" do
    expect(remote.host).to eq("server.example")
  end

  it "translates a path under a prefix each way, and leaves anything else alone" do
    expect(remote.to_remote("/Users/me/Source/app")).to eq("/home/me/Source/app")
    expect(remote.to_remote("/Users/me")).to eq("/home/me")
    expect(remote.to_remote("/Volumes/code/app")).to eq("/srv/code/app")
    expect(remote.to_local("/home/me/Source/app")).to eq("/Users/me/Source/app")
    expect(remote.to_remote("/Users/meg/app")).to eq("/Users/meg/app")
    expect(remote.to_local("/opt/app")).to eq("/opt/app")
  end

  it "ignores a malformed pair" do
    expect(described_class.new("http://x", "/a,=/b,/c=").prefixes).to eq([])
  end

  describe "a Client given it" do
    let(:mcp) { instance_double(PaneyardSandbox::McpClient) }
    let(:client) { PaneyardPlugin::Client.new(remote.url, paths: remote) }

    before { allow(PaneyardSandbox::McpClient).to receive(:new).with("http://server.example:7263/mcp/admin", anything).and_return(mcp) }

    it "shows workspaces at their local paths" do
      allow(mcp).to receive(:call_tool).with("list_workspaces")
        .and_return("workspaces" => [ { "name" => "app", "repositoryPath" => "/home/me/Source/app" } ])

      expect(client.workspaces).to eq([ { "name" => "app", "repositoryPath" => "/Users/me/Source/app" } ])
    end

    it "registers a local checkout by its remote path" do
      allow(mcp).to receive(:call_tool).with("register_workspace", path: "/home/me/Source/app")
        .and_return("name" => "app", "repositoryPath" => "/home/me/Source/app")

      expect(client.register(path: "/Users/me/Source/app")).to include("repositoryPath" => "/Users/me/Source/app")
    end
  end
end
