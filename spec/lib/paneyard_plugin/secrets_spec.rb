require "spec_helper"
require "tmpdir"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::Secrets do
  it "generates a secret_key_base once, private to the operator, and reuses it" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state", "secret_key_base")

      first = described_class.secret_key_base(path)

      expect(first).to match(/\A\h{128}\z/)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(described_class.secret_key_base(path)).to eq(first)
    end
  end

  it "keeps a secret that is already there" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "secret_key_base")
      File.write(path, "existing-secret\n")

      expect(described_class.secret_key_base(path)).to eq("existing-secret")
    end
  end

  it "agrees with itself when two starts race" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "secret_key_base")

      secrets = Array.new(4) { Thread.new { described_class.secret_key_base(path) } }.map(&:value)

      expect(secrets.uniq).to eq([ File.read(path) ])
    end
  end
end
