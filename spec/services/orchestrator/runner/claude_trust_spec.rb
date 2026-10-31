require "rails_helper"

RSpec.describe Orchestrator::Runner::ClaudeTrust, :claude_trust do
  let(:dir) { Dir.mktmpdir }
  let(:config_path) { File.join(dir, ".claude.json") }
  let(:worktree) { "/repos/app/fix-thing-a1b2" }

  after { FileUtils.rm_rf(dir) }

  def config = JSON.parse(File.read(config_path))

  it "marks the folder as trusted, keeping everything else in the config" do
    File.write(config_path, JSON.generate("userID" => "u", "projects" => { worktree => { "allowedTools" => [ "x" ] } }))

    expect(described_class.trust!(worktree, config_paths: [ config_path ])).to be(true)
    expect(config["userID"]).to eq("u")
    expect(config.dig("projects", worktree)).to eq("allowedTools" => [ "x" ], "hasTrustDialogAccepted" => true)
    expect(Dir.children(dir)).to eq([ ".claude.json" ])
  end

  it "keeps the config's mode" do
    File.write(config_path, "{}")
    File.chmod(0o600, config_path)
    described_class.trust!(worktree, config_paths: [ config_path ])
    expect(File.stat(config_path).mode & 0o777).to eq(0o600)
  end

  it "creates the config when claude has none yet" do
    described_class.trust!(worktree, config_paths: [ config_path ])
    expect(config.dig("projects", worktree, "hasTrustDialogAccepted")).to be(true)
  end

  it "leaves an already-trusted folder's config untouched" do
    File.write(config_path, JSON.generate("projects" => { worktree => { "hasTrustDialogAccepted" => true } }))
    expect { expect(described_class.trust!(worktree, config_paths: [ config_path ])).to be(false) }
      .not_to(change { File.read(config_path) })
  end

  it "marks every config it is given, reporting whether any changed" do
    other = File.join(dir, "config", "claude", ".claude.json")
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, JSON.generate("projects" => { worktree => { "hasTrustDialogAccepted" => true } }))

    expect(described_class.trust!(worktree, config_paths: [ config_path, other ])).to be(true)
    expect(config.dig("projects", worktree, "hasTrustDialogAccepted")).to be(true)
    expect(described_class.trust!(worktree, config_paths: [ config_path, other ])).to be(false)
  end

  describe ".config_paths" do
    let(:home) { Dir.mktmpdir }

    before do
      allow(Dir).to receive(:home).and_return(home)
      allow(ENV).to receive(:[]).and_call_original
    end

    after { FileUtils.rm_rf(home) }

    it "uses CLAUDE_CONFIG_DIR when set, else the home directory" do
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("/cfg")
      expect(described_class.config_paths).to eq([ "/cfg/.claude.json" ])

      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
      expect(described_class.config_paths).to eq([ File.join(home, ".claude.json") ])
    end

    # The plugin daemon has no CLAUDE_CONFIG_DIR while the operator's shell
    # points claude at ~/.config/claude.
    it "adds the usual configs that exist, whatever this process's environment says" do
      xdg = File.join(home, ".config", "claude", ".claude.json")
      FileUtils.mkdir_p(File.dirname(xdg))
      File.write(xdg, "{}")
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)

      expect(described_class.config_paths).to eq([ File.join(home, ".claude.json"), xdg ])
    end
  end
end
