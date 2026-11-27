require "spec_helper"
require_relative "../../../lib/paneyard_plugin"
require "tmpdir"
require "fileutils"

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

  describe "hosting jobs here too (PANEYARD_RUNNER_URL)" do
    it "is off without PANEYARD_RUNNER_URL, and names the runner after this machine by default" do
      expect(described_class.from("PANEYARD_REMOTE_URL" => "http://server.example:7263")).not_to be_runner

      hosting = described_class.from("PANEYARD_REMOTE_URL" => "http://server.example:7263",
        "PANEYARD_RUNNER_URL" => "https://laptop.ts.net:7264/")
      expect(hosting).to be_runner
      expect(hosting.runner_url).to eq("https://laptop.ts.net:7264")
      expect(hosting.runner_name).to eq(Socket.gethostname.split(".").first.downcase)
      expect(described_class.new("http://s", "", runner_url: "http://x", runner_name: "local").runner_name).to eq("local-remote")
    end

    it "offers as checkouts the workspaces whose repository (translated to this machine) is here" do
      here = Dir.mktmpdir("checkout-here")
      FileUtils.mkdir_p(File.join(here, ".git"))

      checkouts = remote.checkouts([ { "name" => "app", "repositoryPath" => here },
        { "name" => "gone", "repositoryPath" => File.join(here, "missing") } ])

      expect(checkouts).to eq([ { "workspace" => "app", "path" => here } ])
    ensure
      FileUtils.rm_rf(here)
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

    it "sets up a project and saves the projects directory by their remote paths, showing them as local ones" do
      allow(mcp).to receive(:call_tool).with("create_workspace", path: "/home/me/Source/notes")
        .and_return("name" => "notes", "repositoryPath" => "/home/me/Source/notes")
      allow(mcp).to receive(:call_tool).with("update_settings", projectsDir: "/home/me/Source")
        .and_return("projectsDir" => "/home/me/Source", "defaultGithubOwner" => nil)

      expect(client.create_workspace(path: "/Users/me/Source/notes")).to include("repositoryPath" => "/Users/me/Source/notes")
      expect(client.update_projects_dir("/Users/me/Source")).to include("projectsDir" => "/Users/me/Source")
      expect(PaneyardSandbox::McpClient).to have_received(:new).with("http://server.example:7263/mcp/admin", hash_including(timeout: 300))
    end
  end
end
