require "spec_helper"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "the plugin runtime installer" do
  let(:root) { Dir.mktmpdir("paneyard-runtime-installer") }
  let(:releases) { File.join(root, "releases") }
  let(:platform) { "x86_64-linux" }

  before do
    FileUtils.mkdir_p(File.join(root, "script"))
    FileUtils.cp(File.expand_path("../../../script/install_plugin_runtime", __dir__), File.join(root, "script"))
    FileUtils.cp(File.expand_path("../../../script/build_plugin_runtime", __dir__), File.join(root, "script"))
    File.write(File.join(root, ".ruby-version"), "ruby-4.0.1\n")
    File.write(File.join(root, "Gemfile"), "source \"https://rubygems.org\"\n")
    File.write(File.join(root, "Gemfile.lock"), "GEM\n\nPLATFORMS\n  ruby\n")
  end

  after { FileUtils.rm_rf(root) }

  def runtime_key
    %w[.ruby-version Gemfile Gemfile.lock script/build_plugin_runtime]
      .map { |path| File.read(File.join(root, path)) }
      .join
      .then { |contents| Digest::SHA256.hexdigest(contents) }
  end

  def make_runtime(checksum: true)
    payload = File.join(root, "payload")
    ruby = File.join(payload, ".paneyard/runtime/bin/ruby")
    FileUtils.mkdir_p(File.dirname(ruby))
    File.write(ruby, <<~SH)
      #!/bin/sh
      case "$*" in
        "-v") echo "ruby 4.0.1 (bundled)" ;;
        "-S bundle check") exit 0 ;;
        *) exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, ruby)
    FileUtils.mkdir_p(File.join(payload, "vendor/bundle"))
    FileUtils.mkdir_p(File.join(payload, ".bundle"))
    File.write(File.join(payload, ".bundle/config"), "---\nBUNDLE_PATH: vendor/bundle\n")

    release = File.join(releases, "runtime-#{runtime_key}")
    FileUtils.mkdir_p(release)
    archive = File.join(release, "paneyard-runtime-#{platform}.tar.gz")
    system("tar", "-czf", archive, "-C", payload, ".paneyard", ".bundle", "vendor", exception: true)
    digest = checksum ? Digest::SHA256.file(archive).hexdigest : "0" * 64
    File.write("#{archive}.sha256", "#{digest}  #{File.basename(archive)}\n")
  end

  def install
    Open3.capture3(
      {
        "PANEYARD_RUNTIME_BASE_URL" => "file://#{releases}",
        "PANEYARD_RUNTIME_PLATFORM" => platform
      },
      "/bin/sh", File.join(root, "script/install_plugin_runtime"), chdir: root
    )
  end

  it "installs and verifies the bundled Ruby and gems without a system Ruby" do
    make_runtime

    stdout, stderr, status = install

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("downloading Ruby and production gems", "ready (ruby 4.0.1 (bundled))",
      "herdr plugin action invoke setup --plugin paneyard")
    expect(File.read(File.join(root, ".paneyard/runtime-key"))).to eq("#{runtime_key}\n")
    expect(File).to be_executable(File.join(root, ".paneyard/runtime/bin/ruby"))
  end

  it "rejects an archive whose checksum does not match" do
    make_runtime(checksum: false)

    _stdout, stderr, status = install

    expect(status).not_to be_success
    expect(stderr).to include("runtime checksum mismatch")
    expect(File).not_to exist(File.join(root, ".paneyard/runtime/bin/ruby"))
  end
end
