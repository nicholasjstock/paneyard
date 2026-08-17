require "rails_helper"

RSpec.describe Orchestrator::TargetPreflight do
  it "checks only the target and selected launcher" do
    root = Dir.mktmpdir("target-preflight")
    run = instance_double(Run, target_root: root, launcher_variant: "ruby")

    expect(described_class.check!(run:, mode: "recording")).to be(true)
  end

  it "does not infer a workspace's language, package manager, or service topology" do
    root = Dir.mktmpdir("target-preflight")
    run = instance_double(Run, target_root: root, launcher_variant: "ruby")

    expect(described_class).not_to receive(:system)
    expect(described_class.check!(run:, mode: "implementation")).to be(true)
  end
end
