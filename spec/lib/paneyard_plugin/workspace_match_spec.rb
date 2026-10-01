require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::WorkspaceMatch do
  let(:base) { File.realpath(Dir.mktmpdir("workspace-match")) }
  let(:workspaces) do
    [
      { "name" => "app", "sourceRoot" => File.join(base, "app", "main") },
      { "name" => "nested", "sourceRoot" => File.join(base, "app", "tools", "main") }
    ]
  end

  after { FileUtils.rm_rf(base) }

  describe ".workspace_for" do
    it "matches the main checkout, a directory in it, and a run worktree beside it" do
      %w[main main/app/models paneyard-fix-1234].each do |dir|
        expect(described_class.workspace_for(workspaces, File.join(base, "app", dir))&.fetch("name")).to eq("app")
      end
    end

    it "prefers the deepest root when roots nest" do
      expect(described_class.workspace_for(workspaces, File.join(base, "app", "tools", "main", "lib"))["name"]).to eq("nested")
    end

    it "matches nothing outside every root" do
      expect(described_class.workspace_for(workspaces, File.join(base, "other", "main"))).to be_nil
      expect(described_class.workspace_for(workspaces, File.join(base, "application"))).to be_nil
      expect(described_class.workspace_for(workspaces, nil)).to be_nil
    end
  end

  describe ".run_in_herdr_workspace" do
    it "finds the run whose session opened that herdr workspace" do
      runs = [
        [ { "name" => "a" }, { "runs" => [ { "runId" => "r1", "session" => { "herdrWorkspace" => "w1" } } ] } ],
        [ { "name" => "b" }, { "runs" => [ { "runId" => "r2" }, { "runId" => "r3", "session" => { "herdrWorkspace" => "w7" } } ] } ]
      ]

      expect(described_class.run_in_herdr_workspace(runs, "w7")).to eq([ { "name" => "b" }, runs[1][1]["runs"][1] ])
      expect(described_class.run_in_herdr_workspace(runs, "w9")).to be_nil
      expect(described_class.run_in_herdr_workspace(runs, nil)).to be_nil
    end
  end

  describe ".registration_name" do
    it "names the workspace after its root, wherever in it the pane is" do
      expect(described_class.registration_name("/code/my-app/main", [])).to eq("my-app")
      expect(described_class.registration_name("/code/my-app/main/lib/deep", [])).to eq("my-app")
      expect(described_class.registration_name("/code/my-app", [])).to eq("my-app")
      expect(described_class.registration_name("/code/my app!", [])).to eq("my-app-")
    end

    it "picks a free name when that one is taken" do
      expect(described_class.registration_name("/code/my-app/main", %w[my-app my-app-2])).to eq("my-app-3")
    end
  end
end
