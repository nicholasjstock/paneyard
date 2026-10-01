require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::WorkspaceMatch do
  let(:base) { File.realpath(Dir.mktmpdir("workspace-match")) }
  let(:workspaces) do
    [
      { "name" => "app", "repositoryPath" => File.join(base, "app") },
      { "name" => "nested", "repositoryPath" => File.join(base, "app", "vendor", "tool") }
    ]
  end

  after { FileUtils.rm_rf(base) }

  describe ".workspace_for" do
    it "matches the checkout and any directory in it" do
      [ "app", "app/lib/models" ].each do |dir|
        expect(described_class.workspace_for(workspaces, File.join(base, dir))&.fetch("name")).to eq("app")
      end
    end

    it "matches a linked worktree of the repository wherever it is, by the repository git names" do
      herdr_worktree = File.join(base, "elsewhere", ".herdr", "worktrees", "app", "paneyard-fix")

      expect(described_class.workspace_for(workspaces, herdr_worktree)).to be_nil
      expect(described_class.workspace_for(workspaces, herdr_worktree, repository: File.join(base, "app"))["name"]).to eq("app")
    end

    it "prefers the deepest repository when checkouts nest" do
      expect(described_class.workspace_for(workspaces, File.join(base, "app", "vendor", "tool", "lib"))["name"]).to eq("nested")
    end

    it "matches nothing outside every repository" do
      expect(described_class.workspace_for(workspaces, File.join(base, "other"))).to be_nil
      expect(described_class.workspace_for(workspaces, File.join(base, "application"))).to be_nil
      expect(described_class.workspace_for(workspaces, nil)).to be_nil
    end
  end

  describe ".repository_of" do
    it "names the main checkout and the branch, from the checkout or a linked worktree of it" do
      repository = File.join(base, "real")
      FileUtils.mkdir_p(repository)
      git = ->(dir, *args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL, exception: true) }
      git.call(repository, "init", "-q", "-b", "main")
      git.call(repository, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "init")
      worktree = File.join(base, "far", "away")
      git.call(repository, "worktree", "add", "-q", "-b", "feature/x", worktree)

      expect(described_class.repository_of(repository)).to eq([ repository, "main" ])
      expect(described_class.repository_of(worktree)).to eq([ repository, "feature/x" ])
      expect(described_class.repository_of(File.join(base, "far"))).to eq([ nil, nil ])
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
end
