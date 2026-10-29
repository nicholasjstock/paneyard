require "rails_helper"

RSpec.describe Orchestrator::Runner::CodexTrust, :claude_trust do
  let(:dir) { Dir.mktmpdir }
  let(:config_path) { File.join(dir, "config.toml") }
  let(:worktree) { "/repos/app/fix-thing-a1b2" }

  after { FileUtils.rm_rf(dir) }

  def trust! = described_class.trust!(worktree, config_paths: [ config_path ])
  def config = File.read(config_path)

  it "appends the folder's table, keeping everything else in the config" do
    File.write(config_path, %(model = "m"\n\n[projects."/other"]\ntrust_level = "trusted"))

    expect(trust!).to be(true)
    expect(config).to eq(%(model = "m"\n\n[projects."/other"]\ntrust_level = "trusted"\n\n) +
      %([projects."/repos/app/fix-thing-a1b2"]\ntrust_level = "trusted"\n))
  end

  it "creates the config when codex has none yet" do
    trust!
    expect(config).to eq(%(\n[projects."/repos/app/fix-thing-a1b2"]\ntrust_level = "trusted"\n))
  end

  it "leaves an already-trusted folder's config untouched" do
    File.write(config_path, %([projects."/repos/app/fix-thing-a1b2"] # mine\ntrust_level = "trusted"\n[x]\ny = 1\n))
    expect { expect(trust!).to be(false) }.not_to(change { config })
  end

  it "trusts a folder whose table is there, rather than adding a second one" do
    File.write(config_path, %([projects."/repos/app/fix-thing-a1b2"]\ntrust_level = "untrusted"\n\n[projects."/b"]\n))
    trust!
    expect(config).to eq(%([projects."/repos/app/fix-thing-a1b2"]\ntrust_level = "trusted"\n\n[projects."/b"]\n))

    File.write(config_path, %([projects."/repos/app/fix-thing-a1b2"]\nother = 1\n[projects."/b"]\ntrust_level = "untrusted"\n))
    trust!
    expect(config).to eq(%([projects."/repos/app/fix-thing-a1b2"]\ntrust_level = "trusted"\nother = 1\n[projects."/b"]\ntrust_level = "untrusted"\n))
  end

  it "leaves a config that names the folder in a shape it does not know alone" do
    File.write(config_path, %([projects]\n"/repos/app/fix-thing-a1b2" = { trust_level = "untrusted" }\n))
    expect { expect(trust!).to be(false) }.not_to(change { config })
  end

  it "keeps the config's mode" do
    File.write(config_path, "")
    File.chmod(0o600, config_path)
    trust!
    expect(File.stat(config_path).mode & 0o777).to eq(0o600)
    expect(Dir.children(dir)).to eq([ "config.toml" ])
  end

  describe ".config_paths" do
    let(:home) { Dir.mktmpdir }

    before do
      allow(Dir).to receive(:home).and_return(home)
      allow(ENV).to receive(:[]).and_call_original
    end

    after { FileUtils.rm_rf(home) }

    it "uses CODEX_HOME when set, else ~/.codex, adding the usual configs that exist" do
      allow(ENV).to receive(:[]).with("CODEX_HOME").and_return("/cfg")
      expect(described_class.config_paths).to eq([ "/cfg/config.toml" ])

      xdg = File.join(home, ".config", "codex", "config.toml")
      FileUtils.mkdir_p(File.dirname(xdg))
      File.write(xdg, "")
      allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
      expect(described_class.config_paths).to eq([ File.join(home, ".codex", "config.toml"), xdg ])
    end
  end
end
