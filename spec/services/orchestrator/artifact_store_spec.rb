require "rails_helper"

RSpec.describe Orchestrator::ArtifactStore do
  it "reads artifacts in bounded byte windows" do
    root_dir = Dir.mktmpdir("artifact-store")
    content = "a" * 2_500
    Orchestrator::ArtifactStore.write(root_dir, "run-1", "report.md", content)

    first = Orchestrator::ArtifactStore.read_window(root_dir, "run-1", "report.md")
    second = Orchestrator::ArtifactStore.read_window(root_dir, "run-1", "report.md", offset: first[:next_offset])

    assert_equal 2_500, first[:total_bytes]
    assert_equal 2_000, first[:content].bytesize
    assert_equal 2_000, first[:next_offset]
    assert first[:truncated]
    assert_equal 500, second[:content].bytesize
    assert_nil second[:next_offset]
    assert_not second[:truncated]
    assert_equal [ "report.md" ], Orchestrator::ArtifactStore.names(root_dir, "run-1")
  ensure
    FileUtils.remove_entry(root_dir) if root_dir && Dir.exist?(root_dir)
  end

  it "reports nested workspace scopes as not existing instead of raising" do
    root_dir = Dir.mktmpdir("artifact-store")
    Orchestrator::ArtifactStore.write(root_dir, "run-1", "report.md", "hello")

    artifacts = Orchestrator::ArtifactStore.collect(
      root_dir, "run-1", [ "report.md", "front/scripts/record-demo.ts" ]
    )[:artifacts]

    found = artifacts.find { |artifact| artifact[:name] == "report.md" }
    missing = artifacts.find { |artifact| artifact[:name] == "front/scripts/record-demo.ts" }

    assert found[:exists]
    assert_not missing[:exists]
    assert_nil missing[:path]
  ensure
    FileUtils.remove_entry(root_dir) if root_dir && Dir.exist?(root_dir)
  end
end
