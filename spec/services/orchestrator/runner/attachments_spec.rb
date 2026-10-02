require "rails_helper"

RSpec.describe Orchestrator::Runner::Attachments do
  let(:root) { Dir.mktmpdir("attachments") }

  after { FileUtils.remove_entry(root) }

  it "stores a run's attachments under the runtime root and lists them back by name" do
    described_class.store(root, "run-1", "b.log", "second")
    path = described_class.store(root, "run-1", "a.db", "first")

    expect(path).to eq(File.join(root, "run-1", "attachments", "a.db"))
    expect(described_class.list(root, "run-1")).to eq(
      [ { "name" => "a.db", "content" => "first" }, { "name" => "b.log", "content" => "second" } ]
    )
  end

  it "still lists an older run's attachments from the repository it kept them in" do
    checkout = Dir.mktmpdir("legacy-checkout")
    FileUtils.mkdir_p(File.join(checkout, ".paneyard", "artifacts", "run-old"))
    File.write(File.join(checkout, ".paneyard", "artifacts", "run-old", "a.txt"), "old")

    expect(described_class.list(root, "run-old", legacy_root: checkout)).to eq([ { "name" => "a.txt", "content" => "old" } ])
  end

  it "lists nothing for a run with no attachments" do
    expect(described_class.list(root, "run-2")).to eq([])
  end

  it "refuses a name that would leave the run's directory" do
    expect { described_class.store(root, "run-1", "../escape", "x") }.to raise_error(ArgumentError, /Unsafe/)
  end
end
