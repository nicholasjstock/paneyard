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

  it "produces a JSON-safe preview even when the 200-byte window cuts a multibyte character in half" do
    root_dir = Dir.mktmpdir("artifact-store")
    # An em dash is 3 bytes (E2 80 94) in UTF-8; 199 filler bytes puts its
    # first byte exactly at the 200-byte preview boundary, reproducing the
    # live "\xE2 from ASCII-8BIT to UTF-8" JSON::GeneratorError this guards
    # against -- reading in binary mode ("rb") tags the preview ASCII-8BIT,
    # under which every byte is "valid" by definition, so a bare `.scrub`
    # was a no-op and the dangling lead byte reached JSON.generate intact.
    content = ("a" * 199) + "—" + "trailing content past the preview window"
    Orchestrator::ArtifactStore.write(root_dir, "run-1", "report.md", content)

    artifacts = Orchestrator::ArtifactStore.collect(root_dir, "run-1", [ "report.md" ])[:artifacts]
    preview = artifacts.first[:preview]

    assert preview.valid_encoding?
    assert_equal Encoding::UTF_8, preview.encoding
    JSON.generate(preview) # raises JSON::GeneratorError if this regresses
  ensure
    FileUtils.remove_entry(root_dir) if root_dir && Dir.exist?(root_dir)
  end
end
