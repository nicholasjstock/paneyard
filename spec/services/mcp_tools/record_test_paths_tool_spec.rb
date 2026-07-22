require "rails_helper"

RSpec.describe McpTools::RecordTestPathsTool do
  it "records only existing workspace-relative test directories" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    FileUtils.mkdir_p(File.join(source_root, "quality", "checks"))
    workspace = Workspace.create!(name: "test-paths-#{SecureRandom.hex(4)}", root_path: project_root)
    run = workspace.runs.create!(
      run_id: "test-paths-#{SecureRandom.hex(4)}", task: "Discover tests", target_root: source_root,
      launcher_variant: "codex", status: "running"
    )

    response = described_class.call(runId: run.run_id, paths: [ "quality/checks" ], server_context: nil)

    expect(response.structured_content).to eq(paths: [ "quality/checks" ])
    expect(workspace.reload.test_write_roots).to eq([ "quality/checks" ])
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "rejects a missing test directory" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    FileUtils.mkdir_p(source_root)
    workspace = Workspace.create!(name: "missing-test-path-#{SecureRandom.hex(4)}", root_path: project_root)
    run = workspace.runs.create!(
      run_id: "missing-test-path-#{SecureRandom.hex(4)}", task: "Discover tests", target_root: source_root,
      launcher_variant: "codex", status: "running"
    )

    response = described_class.call(runId: run.run_id, paths: [ "missing" ], server_context: nil)

    expect(response.error?).to be(true)
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end
end
