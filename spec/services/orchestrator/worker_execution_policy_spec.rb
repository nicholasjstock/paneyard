require "rails_helper"

RSpec.describe Orchestrator::WorkerExecutionPolicy do
  it "denies repository writes for a source-protected target while retaining Bash" do
    root = Dir.mktmpdir("artifact-policy")
    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    expect(policy.claude_tools.split(",")).to include("Bash")
    expect(policy.claude_tools.split(",")).not_to include("Edit", "Write")
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to eq([])
    expect(policy.codex_config_overrides.join(" ")).to include('"."="read"')
  end

  it "grants read access beyond the workspace root and opens the network, so a host's toolchain managers (asdf, Docker) are reachable" do
    root = Dir.mktmpdir("artifact-policy")
    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    overrides = policy.codex_config_overrides.join(" ")
    expect(overrides).to include('":root"="read"')
    expect(overrides).to include('permissions.worker.network={"enabled"=true}')
  end

  it "grants write access to non-source directories (caches, logs) even for a source-protected worker, since protected_patterns protects declared source, not scratch space" do
    root = Dir.mktmpdir("scratch-policy")
    FileUtils.mkdir_p(File.join(root, "node_modules", ".vite-temp"))
    FileUtils.mkdir_p(File.join(root, "app"))
    FileUtils.mkdir_p(File.join(root, "log"))

    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: [],
      protected_patterns: [ "app/**/*" ]
    )

    overrides = policy.codex_config_overrides.join(" ")
    expect(overrides).to include('"node_modules"="write"')
    expect(overrides).to include('"log"="write"')
    expect(overrides).not_to include('"app"="write"')
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(File.join(root, "node_modules"))
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(File.join(root, "log"))
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).not_to include(File.join(root, "app"))
    expect(policy.claude_settings["permissions"]["allow"]).to include("Write(#{File.join(root, 'node_modules')}/**)")
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "never grants write access to .git, even though protected_patterns can't declare it as protected" do
    root = Dir.mktmpdir("scratch-policy")
    FileUtils.mkdir_p(File.join(root, ".git"))
    FileUtils.mkdir_p(File.join(root, "app"))

    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: [],
      protected_patterns: [ "app/**/*" ]
    )

    expect(policy.scratch_writable_relative_paths).not_to include(".git")
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).not_to include(File.join(root, ".git"))
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "fails closed (nothing is scratch) when no protected_patterns are declared yet" do
    root = Dir.mktmpdir("scratch-policy")
    FileUtils.mkdir_p(File.join(root, "log"))

    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    expect(policy.scratch_writable_relative_paths).to be_empty
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to eq([])
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "rejects repository grants for source-protected workers" do
    root = Dir.mktmpdir("artifact-policy")

    expect do
      described_class.new(
        root_dir: root, mode: "diagnosis", write_scope: "source_protected",
        allowed_paths: [ "Gemfile.lock" ]
      )
    end.to raise_error(ArgumentError, /source_protected workers cannot authorize/)
  end

  it "grants full recursive write, including .git, for a git_managed worker" do
    root = Dir.mktmpdir("git-managed-policy")
    FileUtils.mkdir_p(File.join(root, ".git"))
    FileUtils.mkdir_p(File.join(root, "app"))

    policy = described_class.new(
      root_dir: root, mode: "implementation", write_scope: "git_managed", allowed_paths: [ "**/*" ],
      protected_patterns: [ "app/**/*" ]
    )

    expect(policy.repository_writable?).to be(true)
    expect(policy.claude_tools.split(",")).to include("Bash", "Edit", "Write")
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(root)
    expect(policy.claude_settings["permissions"]["allow"]).to include("Edit(#{root}/**)", "Write(#{root}/**)")
    expect(policy.codex_config_overrides.join(" ")).to include('"."="write"')
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "requires allowed paths for a git_managed worker" do
    root = Dir.mktmpdir("git-managed-policy")

    expect do
      described_class.new(root_dir: root, mode: "implementation", write_scope: "git_managed", allowed_paths: [])
    end.to raise_error(ArgumentError, /git_managed workers require allowed paths/)
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "rejects absolute and escaping paths while resolving a protected glob to its source root" do
    root = Dir.mktmpdir("scoped-policy")
    FileUtils.mkdir_p(File.join(root, "app"))

    policy = described_class.new(
      root_dir: root, mode: "implementation", write_scope: "scoped_changes", allowed_paths: [ "app/**/*.rb" ]
    )
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(File.join(root, "app"))
    expect(policy.claude_settings["permissions"]["allow"]).to include("Edit(#{File.join(root, "app")}/**)")

    [ "/tmp/file", "../outside" ].each do |path|
      expect do
        described_class.new(
          root_dir: root, mode: "implementation", write_scope: "scoped_changes",
          allowed_paths: [ path ]
        )
      end.to raise_error(ArgumentError)
    end
  end
end
