require "rails_helper"

RSpec.describe RegisteredRunner do
  describe ".local" do
    it "makes the local runner the first time it is needed, and finds it after that" do
      expect(described_class.count).to eq(0)

      local = described_class.local

      expect(local).to have_attributes(name: "local", kind: "local", url: nil, max_concurrent_runs: nil)
      expect(described_class.local).to eq(local)
      expect(described_class.count).to eq(1)
    end

    it "finds the local runner whatever it is called" do
      local = described_class.create!(name: "this-machine", kind: "local")

      expect(described_class.local).to eq(local)
    end
  end

  it "has one local runner" do
    described_class.local

    expect(described_class.new(name: "another", kind: "local")).not_to be_valid
  end

  it "needs a url for a remote runner and none for the local one" do
    expect(described_class.new(name: "mac", kind: "remote")).not_to be_valid
    expect(described_class.new(name: "mac", kind: "remote", url: "http://mac.tailnet:3100")).to be_valid
    expect(described_class.new(name: "here", kind: "local", url: "http://localhost:3100")).not_to be_valid
  end

  it "rejects an unknown kind, a duplicate name and a cap below one" do
    described_class.create!(name: "mac", kind: "remote", url: "http://mac.tailnet:3100")

    expect(described_class.new(name: "x", kind: "cloud", url: "http://x")).not_to be_valid
    expect(described_class.new(name: "mac", kind: "remote", url: "http://other")).not_to be_valid
    expect(described_class.new(name: "y", kind: "remote", url: "http://y", max_concurrent_runs: 0)).not_to be_valid
  end

  it "never removes the local runner" do
    local = described_class.local

    expect(local.destroy).to be(false)
    expect(described_class.exists?(local.id)).to be(true)
  end
end
