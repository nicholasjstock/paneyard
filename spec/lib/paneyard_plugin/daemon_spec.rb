require "spec_helper"
require "tmpdir"
require "fileutils"
require "socket"
require "open3"
require_relative "../../../lib/paneyard_plugin"

# Real processes, standing in for bin/production: a tiny server that answers
# /up on PORT and records the environment it was started with, so start,
# reuse, restart and stop are exercised for real without booting Rails.
RSpec.describe PaneyardPlugin::Daemon do
  STAND_IN = <<~'RUBY'.freeze
    require "socket"
    require "json"
    server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
    File.write(File.join(ENV.fetch("STAND_IN_DIR"), "started-#{Process.pid}.json"), JSON.generate(ENV.to_h))
    trap("TERM") { exit }
    loop do
      client = server.accept
      nil while (line = client.gets) && line != "\r\n"
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
    end
  RUBY

  let(:dir) { File.realpath(Dir.mktmpdir("paneyard-plugin-daemon")) }
  let(:stand_in_dir) { File.join(dir, "stand-in").tap { |path| FileUtils.mkdir_p(path) } }
  let(:paths) do
    PaneyardPlugin::Paths.new(env: {
      "HERDR_PLUGIN_STATE_DIR" => File.join(dir, "state"), "HERDR_PLUGIN_CONFIG_DIR" => File.join(dir, "config"),
      "HERDR_PLUGIN_ROOT" => PaneyardPlugin::APP_ROOT
    })
  end
  let(:base_env) do
    {
      "PATH" => ENV["PATH"], "STAND_IN_DIR" => stand_in_dir, "BUNDLE_GEMFILE" => "/elsewhere/Gemfile",
      "RAILS_ENV" => "development", "PANEYARD_RUN_TOKEN" => "a-run-session's-capability"
    }
  end
  let(:daemons) { [] }

  def daemon(socket: "/tmp/herdr-a.sock", command: [ RbConfig.ruby, "-e", STAND_IN ], timeout: 15)
    described_class.new(paths:, herdr_socket: socket, env: base_env, command:, startup_timeout: timeout, stop_grace: 5)
      .tap { |created| daemons << created }
  end

  def started_envs
    Dir[File.join(stand_in_dir, "started-*.json")].map { |path| JSON.parse(File.read(path)) }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  after do
    daemons.first&.stop
    FileUtils.rm_rf(dir)
  end

  it "starts once, and a second call finds it running instead of starting another" do
    first = daemon.ensure_running
    second = daemon.ensure_running

    expect(first.outcome).to eq(:started)
    expect(second).to have_attributes(outcome: :running, pid: first.pid, port: first.port, url: "http://127.0.0.1:#{first.port}")
    expect(started_envs.size).to eq(1)
    expect(File.read(paths.port_file)).to eq(first.port.to_s)
    expect(File.read(paths.url_file)).to eq(first.url)
    expect(daemon.status).to have_attributes(pid: first.pid)
  end

  it "gives the daemon its state directory, generated secret and herdr socket, and none of the caller's bundle or run" do
    File.write(paths.env_file.tap { |path| FileUtils.mkdir_p(File.dirname(path)) },
      "PANEYARD_MAX_CONCURRENT_RUNS=2\nHERDR_SOCKET_PATH=/not/this/one.sock\n")

    result = daemon.ensure_running
    env = started_envs.first

    expect(env).to include(
      "RAILS_ENV" => "production", "PORT" => result.port.to_s, "BINDING" => "127.0.0.1",
      "PANEYARD_RAILS_URL" => result.url, "PANEYARD_STORAGE_DIR" => paths.storage_dir,
      "PANEYARD_RUNTIME_DIR" => paths.runtime_dir, "PIDFILE" => paths.puma_pid_file,
      "HERDR_SOCKET_PATH" => "/tmp/herdr-a.sock", "SECRET_KEY_BASE" => File.read(paths.secret_file),
      "PANEYARD_MAX_CONCURRENT_RUNS" => "2"
    )
    expect(env["PATH"]).to start_with("#{File.dirname(RbConfig.ruby)}#{File::PATH_SEPARATOR}")
    expect(env.keys).not_to include("BUNDLE_GEMFILE", "PANEYARD_RUN_TOKEN")
    expect(File.read(paths.env_file)).to include("PANEYARD_MAX_CONCURRENT_RUNS=2")
  end

  it "writes a sample .env on first start, for the operator to fill in" do
    daemon.ensure_running

    expect(File.read(paths.env_file)).to eq(PaneyardPlugin::EnvFile::SAMPLE)
  end

  it "starts one daemon when several callers race" do
    results = Array.new(4) { Thread.new { daemon.ensure_running } }.map(&:value)

    expect(results.map(&:pid).uniq.size).to eq(1)
    expect(results.map(&:outcome).tally).to eq(started: 1, running: 3)
    expect(started_envs.size).to eq(1)
  end

  it "keeps its port across restarts, and picks another only when something else took it" do
    first = daemon.ensure_running
    daemon.stop
    again = daemon.ensure_running
    expect(again).to have_attributes(outcome: :started, port: first.port)
    expect(again.port_changed?).to be(false)
    daemon.stop

    squatter = TCPServer.new("127.0.0.1", first.port)
    moved = daemon.ensure_running
    expect(moved.port).not_to eq(first.port)
    expect(moved).to have_attributes(previous_port: first.port, port_changed?: true)
    expect(File.read(paths.port_file)).to eq(moved.port.to_s)
    expect(daemon.ensure_running.port_changed?).to be(false)
  ensure
    squatter&.close
  end

  it "uses a PORT pinned in the .env, and refuses it when it is taken" do
    pinned = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    FileUtils.mkdir_p(paths.config_dir)
    File.write(paths.env_file, "PORT=#{pinned}\n")

    expect(daemon.ensure_running.port).to eq(pinned)
    daemon.stop

    squatter = TCPServer.new("127.0.0.1", pinned)
    expect { daemon.ensure_running }.to raise_error(PaneyardPlugin::Error, /PORT #{pinned}.*already in use/)
  ensure
    squatter&.close
  end

  it "restarts on new code or settings, so a reinstall or an edited .env takes effect" do
    first = daemon.ensure_running
    File.write(paths.env_file, "PANEYARD_MAX_CONCURRENT_RUNS=7\n")

    second = daemon.ensure_running

    expect(second).to have_attributes(outcome: :restarted, port: first.port)
    expect(second.pid).not_to eq(first.pid)
    expect(alive?(first.pid)).to be(false)
    expect(started_envs.map { |env| env["PANEYARD_MAX_CONCURRENT_RUNS"] }).to include("7")
  end

  describe "the checked-out commit" do
    let(:root) { File.join(dir, "plugin").tap { |path| FileUtils.mkdir_p(path) } }
    let(:paths) do
      PaneyardPlugin::Paths.new(env: {
        "HERDR_PLUGIN_STATE_DIR" => File.join(dir, "state"), "HERDR_PLUGIN_CONFIG_DIR" => File.join(dir, "config"),
        "HERDR_PLUGIN_ROOT" => root
      })
    end

    def git(*args, chdir: root)
      out, status = Open3.capture2e("git", "-c", "user.name=Spec", "-c", "user.email=spec@example.test",
        "-c", "commit.gpgsign=false", *args, chdir:)
      raise "git #{args.join(' ')}: #{out}" unless status.success?

      out.strip
    end

    def commit(message)
      File.write(File.join(root, "herdr-plugin.toml"), "version = \"1.0.0\"\n# #{message}\n")
      File.write(File.join(root, "Gemfile.lock"), "unchanged\n")
      git("add", ".")
      git("commit", "-q", "-m", message)
      git("rev-parse", "HEAD")
    end

    before { git("init", "-q", "-b", "main") }

    # `herdr plugin install <owner>/paneyard --ref <branch>` again: same
    # manifest version, same lockfile, new code.
    it "restarts the daemon on a reinstall at a new commit, as a fresh start of the same command" do
      commit("first")
      first = daemon.ensure_running
      expect(daemon.ensure_running.outcome).to eq(:running)

      commit("second")
      second = daemon.ensure_running

      expect(second).to have_attributes(outcome: :restarted, port: first.port)
      expect(alive?(first.pid)).to be(false)
      # The same command as any start, so bin/production's db:prepare runs.
      expect(started_envs.size).to eq(2)
    end

    it "does not restart a linked checkout for an uncommitted edit" do
      commit("first")
      first = daemon.ensure_running

      File.write(File.join(root, "app.rb"), "edited\n")

      expect(daemon.ensure_running).to have_attributes(outcome: :running, pid: first.pid)
    end

    it "reads it from a detached HEAD, a branch, packed refs and a linked worktree" do
      sha = commit("first")
      expect(daemon.code_revision).to eq(sha)

      git("checkout", "-q", "--detach")
      expect(daemon.code_revision).to eq(sha)
      git("checkout", "-q", "main")

      git("pack-refs", "--all", "--prune")
      expect(File.exist?(File.join(root, ".git", "refs", "heads", "main"))).to be(false)
      expect(daemon.code_revision).to eq(sha)

      linked = File.join(dir, "linked")
      git("worktree", "add", "-q", "-b", "elsewhere", linked)
      File.write(File.join(linked, "herdr-plugin.toml"), "version = \"1.0.0\"\n# linked\n")
      git("commit", "-q", "-am", "linked", chdir: linked)
      linked_paths = PaneyardPlugin::Paths.new(env: { "HERDR_PLUGIN_STATE_DIR" => File.join(dir, "state"), "HERDR_PLUGIN_ROOT" => linked })
      expect(described_class.new(paths: linked_paths).code_revision).to eq(git("rev-parse", "HEAD", chdir: linked))
    end

    it "falls back to the version and lockfile outside a git checkout" do
      FileUtils.rm_rf(File.join(root, ".git"))

      expect(daemon.code_revision).to be_nil
      expect { daemon.fingerprint }.not_to raise_error
    end
  end

  it "leaves a daemon started for another herdr server alone" do
    first = daemon(socket: "/tmp/herdr-a.sock").ensure_running

    other = daemon(socket: "/tmp/herdr-b.sock").ensure_running

    expect(other).to have_attributes(outcome: :elsewhere, pid: first.pid, herdr_socket: "/tmp/herdr-a.sock")
    expect(alive?(first.pid)).to be(true)
  end

  it "moves to this herdr server on an explicit restart" do
    first = daemon(socket: "/tmp/herdr-a.sock").ensure_running

    moved = daemon(socket: "/tmp/herdr-b.sock").restart

    expect(moved).to have_attributes(outcome: :restarted, herdr_socket: "/tmp/herdr-b.sock")
    expect(alive?(first.pid)).to be(false)
  end

  it "does not mistake a stale pid file, or a reused pid, for a running daemon" do
    FileUtils.mkdir_p(paths.state_dir)
    File.write(paths.daemon_file, JSON.generate("pid" => 999_999, "port" => 1))
    expect(daemon.ensure_running.outcome).to eq(:started)
    daemon.stop

    # This very process: alive, but not the daemon that was recorded.
    File.write(paths.daemon_file, JSON.generate("pid" => Process.pid, "identity" => "Mon Jan  1 00:00:00 2001", "port" => 1))
    expect(daemon.status).to be_nil
    expect(daemon.ensure_running.outcome).to eq(:started)
  end

  it "stops it, and says whether it was running" do
    result = daemon.ensure_running

    expect(daemon.stop).to be(true)
    expect(alive?(result.pid)).to be(false)
    expect(daemon.status).to be_nil
    expect(daemon.stop).to be(false)
  end

  it "fails with the log when the daemon dies while starting" do
    crashing = daemon(command: [ RbConfig.ruby, "-e", "warn 'simulated boot failure'; exit 1" ])

    expect { crashing.ensure_running }.to raise_error(PaneyardPlugin::Error, /exited while starting.*simulated boot failure/m)
    expect(File.exist?(paths.daemon_file)).to be(false)
  end
end
