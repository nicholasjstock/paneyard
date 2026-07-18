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
  ensure
    FileUtils.remove_entry(root_dir) if root_dir && Dir.exist?(root_dir)
  end
end
