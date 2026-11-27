require "rails_helper"
require "open3"

# Real git: a runner without a checkout of a workspace clones its origin, and
# whether what is already at the path may stand in for that clone is only
# meaningful against real repositories.
RSpec.describe Orchestrator::Runner::Repositories, ".ensure_checkout" do
  let(:tmp) { File.realpath(Dir.mktmpdir("ensure-checkout")) }
  let(:origin) { File.join(tmp, "origin.git") }
  let(:projects) { File.join(tmp, "Source") }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  # A bare origin with main (its HEAD) and develop.
  before do
    seed = File.join(tmp, "seed")
    git(tmp, "init", "--bare", "--initial-branch=main", origin)
    git(tmp, "clone", "--quiet", origin, seed)
    git(seed, "config", "user.email", "spec@example.test")
    git(seed, "config", "user.name", "Spec")
    File.write(File.join(seed, "README.md"), "hi\n")
    git(seed, "add", ".")
    git(seed, "commit", "-m", "initial")
    git(seed, "push", "--quiet", "origin", "main")
    git(seed, "switch", "--quiet", "-c", "develop")
    git(seed, "push", "--quiet", "origin", "develop")
  end

  def ensure_checkout(path, origin_url: origin, default_base_branch: "main")
    described_class.ensure_checkout(path:, origin_url:, default_base_branch:)
  end

  it "clones into a path with nothing there, parents and all, and checks the clone" do
    path = File.join(projects, "app")

    result = ensure_checkout(path)

    expect(result).to include("repository_path" => path, "default_base_branch" => "main", "origin_url" => origin,
      "problems" => [], "cloned" => true)
    expect(git(path, "rev-parse", "--abbrev-ref", "HEAD")).to eq("main")
  end

  it "makes the workspace's default branch a local one when origin's HEAD is another" do
    path = File.join(projects, "app")

    result = ensure_checkout(path, default_base_branch: "develop")

    expect(result).to include("default_base_branch" => "develop", "problems" => [], "cloned" => true)
    expect(git(path, "rev-parse", "--abbrev-ref", "develop@{upstream}")).to eq("origin/develop")
    expect(git(path, "rev-parse", "--abbrev-ref", "HEAD")).to eq("main")
  end

  it "clones into an empty directory that is already there" do
    path = File.join(projects, "app")
    FileUtils.mkdir_p(path)

    expect(ensure_checkout(path)).to include("cloned" => true, "problems" => [])
  end

  it "reuses a clone of the same origin, whatever it has checked out or changed, without touching it" do
    path = File.join(projects, "app")
    git(tmp, "clone", "--quiet", origin, path)
    git(path, "switch", "--quiet", "develop")
    File.write(File.join(path, "wip.txt"), "mine\n")

    result = ensure_checkout(path)

    expect(result).to include("repository_path" => path, "cloned" => false, "problems" => [])
    expect(git(path, "rev-parse", "--abbrev-ref", "HEAD")).to eq("develop")
    expect(File.read(File.join(path, "wip.txt"))).to eq("mine\n")
  end

  it "reuses a clone whose origin names the same repository another way" do
    path = File.join(projects, "app")
    git(tmp, "clone", "--quiet", origin, path)
    git(path, "remote", "set-url", "origin", "file://#{origin}")

    expect(ensure_checkout(path)).to include("cloned" => false)
  end

  it "refuses a checkout of another origin, and leaves it alone" do
    other = File.join(tmp, "other.git")
    git(tmp, "init", "--bare", "--initial-branch=main", other)
    path = File.join(projects, "app")
    git(tmp, "clone", "--quiet", "--", other, path)

    expect { ensure_checkout(path) }.to raise_error(Orchestrator::Runner::Error, /already a checkout of #{Regexp.escape(other)}/)
    expect(git(path, "remote", "get-url", "origin")).to eq(other)
  end

  it "refuses a checkout with no origin" do
    path = File.join(projects, "app")
    FileUtils.mkdir_p(path)
    git(path, "init", "--quiet")

    expect { ensure_checkout(path) }.to raise_error(Orchestrator::Runner::Error, /no origin remote/)
  end

  it "refuses a directory with files that is not a checkout, or is only inside one, and leaves it alone" do
    plain = File.join(projects, "plain")
    FileUtils.mkdir_p(plain)
    File.write(File.join(plain, "notes.txt"), "keep me\n")
    expect { ensure_checkout(plain) }.to raise_error(Orchestrator::Runner::Error, /not a git checkout/)
    expect(Dir.children(plain)).to eq([ "notes.txt" ])

    host = File.join(tmp, "host")
    git(tmp, "clone", "--quiet", origin, host)
    inside = File.join(host, "docs")
    FileUtils.mkdir_p(inside)
    File.write(File.join(inside, "x.md"), "x\n")
    expect { ensure_checkout(inside) }.to raise_error(Orchestrator::Runner::Error, /not a git checkout/)
  end

  it "refuses a file at the path" do
    FileUtils.mkdir_p(projects)
    file = File.join(projects, "app")
    File.write(file, "x")

    expect { ensure_checkout(file) }.to raise_error(Orchestrator::Runner::Error, /not a directory/)
    expect(File.read(file)).to eq("x")
  end

  it "fails a clone it cannot make with git's reason, leaving no directory of its own behind" do
    path = File.join(projects, "app")

    expect { ensure_checkout(path, origin_url: File.join(tmp, "missing.git")) }
      .to raise_error(Orchestrator::Runner::Error, /git clone .* failed: .*credentials/m)
    expect(File.exist?(path)).to be(false)
  end

  it "refuses a relative path and a blank origin" do
    expect { ensure_checkout("Source/app") }.to raise_error(Orchestrator::Runner::Error, /absolute path/)
    expect { ensure_checkout(File.join(projects, "app"), origin_url: " ") }.to raise_error(Orchestrator::Runner::Error, /no origin/)
  end

  describe ".same_origin?" do
    it "matches the same repository over https, ssh and scp-like URLs, and nothing else" do
      expect(described_class.same_origin?("https://github.com/Me/app.git", "git@github.com:Me/app")).to be(true)
      expect(described_class.same_origin?("ssh://git@GitHub.com/Me/app.git/", "https://github.com/Me/app")).to be(true)
      expect(described_class.same_origin?("https://github.com/Me/app", "https://github.com/Me/other")).to be(false)
      expect(described_class.same_origin?("https://github.com/Me/app", "https://gitlab.com/Me/app")).to be(false)
    end
  end

  describe "in a sandbox" do
    let(:sandbox_root) { File.join(tmp, "sandbox") }

    around do |example|
      saved = ENV.to_h.slice("PANEYARD_SANDBOX", "PANEYARD_SANDBOX_ROOT")
      FileUtils.mkdir_p(sandbox_root)
      ENV["PANEYARD_SANDBOX"] = "1"
      ENV["PANEYARD_SANDBOX_ROOT"] = sandbox_root
      example.run
    ensure
      %w[PANEYARD_SANDBOX PANEYARD_SANDBOX_ROOT].each { |key| ENV.delete(key) }
      ENV.update(saved)
    end

    it "clones only into its root, and only from an origin inside it" do
      expect { ensure_checkout(File.join(projects, "app")) }.to raise_error(Orchestrator::Runner::Error, /sandbox refuses to clone a repository into/)
      expect { ensure_checkout(File.join(sandbox_root, "app")) }.to raise_error(Orchestrator::Runner::Error, /sandbox refuses to clone from an origin outside/)
      expect { ensure_checkout(File.join(sandbox_root, "app"), origin_url: "https://github.com/me/app.git") }
        .to raise_error(Orchestrator::Runner::Error, /sandbox refuses to clone from an origin outside/)
      expect(File.exist?(File.join(sandbox_root, "app"))).to be(false)

      inside = File.join(sandbox_root, "origin.git")
      git(tmp, "clone", "--quiet", "--bare", origin, inside)
      expect(ensure_checkout(File.join(sandbox_root, "app"), origin_url: inside)).to include("cloned" => true, "problems" => [])
    end
  end
end
