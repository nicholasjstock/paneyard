require "rails_helper"

RSpec.describe Orchestrator::Runner::ClaudeTrust, :claude_trust do
  let(:dir) { Dir.mktmpdir }
  let(:config_path) { File.join(dir, ".claude.json") }
  let(:worktree) { "/repos/app/fix-thing-a1b2" }

  after { FileUtils.rm_rf(dir) }

  def config = JSON.parse(File.read(config_path))

  it "marks the folder as trusted, keeping everything else in the config" do
    File.write(config_path, JSON.generate("userID" => "u", "projects" => { worktree => { "allowedTools" => [ "x" ] } }))

    expect(described_class.trust!(worktree, config_path:)).to be(true)
    expect(config["userID"]).to eq("u")
    expect(config.dig("projects", worktree)).to eq("allowedTools" => [ "x" ], "hasTrustDialogAccepted" => true)
    expect(Dir.children(dir)).to eq([ ".claude.json" ])
  end

  it "creates the config when claude has none yet" do
    described_class.trust!(worktree, config_path:)
    expect(config.dig("projects", worktree, "hasTrustDialogAccepted")).to be(true)
  end

  it "leaves an already-trusted folder's config untouched" do
    File.write(config_path, JSON.generate("projects" => { worktree => { "hasTrustDialogAccepted" => true } }))
    expect { expect(described_class.trust!(worktree, config_path:)).to be(false) }
      .not_to(change { File.read(config_path) })
  end

  it "uses CLAUDE_CONFIG_DIR when set, else the home directory" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("/cfg")
    expect(described_class.config_path).to eq("/cfg/.claude.json")

    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
    expect(described_class.config_path).to eq(File.join(Dir.home, ".claude.json"))
  end
end
