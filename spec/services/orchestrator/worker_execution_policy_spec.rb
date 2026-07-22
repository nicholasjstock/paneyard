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

  it "grants write access to gitignored directories (caches) even for a source-protected worker, since write_scope protects source, not caches" do
    root = Dir.mktmpdir("gitignore-policy")
    system("git", "-C", root, "init", "--quiet", exception: true)
    File.write(File.join(root, ".gitignore"), "node_modules/\n.env.local\n")
    FileUtils.mkdir_p(File.join(root, "node_modules", ".vite-temp"))
    File.write(File.join(root, "node_modules", ".vite-temp", "config.mjs"), "// scratch")
    File.write(File.join(root, ".env.local"), "SECRET=shh")

    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    overrides = policy.codex_config_overrides.join(" ")
    expect(overrides).to include('"node_modules"="write"')
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(File.join(root, "node_modules"))
    expect(policy.claude_settings["permissions"]["allow"]).to include("Write(#{File.join(root, 'node_modules')})")
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "excludes individual gitignored files (secrets, local state) from the cache write grant, even though they're not source either" do
    root = Dir.mktmpdir("gitignore-policy")
    system("git", "-C", root, "init", "--quiet", exception: true)
    File.write(File.join(root, ".gitignore"), ".env.local\nlocal_secret.txt\n")
    File.write(File.join(root, ".env.local"), "SECRET=shh")
    File.write(File.join(root, "local_secret.txt"), "shh")

    policy = described_class.new(
      root_dir: root, mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    expect(policy.git_ignored_relative_paths).to be_empty
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to eq([])
    overrides = policy.codex_config_overrides.join(" ")
    expect(overrides).not_to include("env.local")
    expect(overrides).not_to include("local_secret.txt")
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

  it "rejects absolute and escaping paths while resolving a protected glob to its source root" do
    root = Dir.mktmpdir("scoped-policy")
    FileUtils.mkdir_p(File.join(root, "app"))

    policy = described_class.new(
      root_dir: root, mode: "implementation", write_scope: "scoped_changes", allowed_paths: [ "app/**/*.rb" ]
    )
    expect(policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")).to include(File.join(root, "app"))

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
