require "spec_helper"
require "fileutils"
require "net/http"
require "stringio"

RSpec.describe "bin/service" do
  let(:script) { File.expand_path("../../bin/service", __dir__) }
  let(:warnings) { [] }
  let(:output) { [] }
  let(:runner) do
    warnings = self.warnings
    output = self.output
    Object.new.tap do |runner|
      runner.define_singleton_method(:warn) { |message| warnings << message }
      runner.define_singleton_method(:puts) { |message| output << message }
      runner.define_singleton_method(:exit) { |status| throw :service_exit, status }
    end
  end

  # Everything but the last line's dispatch, so the script's methods can be
  # called directly.
  def load_script
    source = File.read(script).split("\nrun_command(ARGV)", 2).first
    eval(source, runner.instance_eval { binding }, script)
  end

  it "reports the log when the production child exits immediately" do
    pid_file_present = false

    allow(FileUtils).to receive(:mkdir_p)
    allow(File).to receive(:open).and_return(StringIO.new)
    allow(File).to receive(:write) { pid_file_present = true }
    allow(File).to receive(:readlines).and_return([ "simulated startup error\n" ])
    allow(File).to receive(:delete) { pid_file_present = false }
    allow(File).to receive(:exist?) do |path|
      path == Object.const_get(:LOG_FILE) || (path == Object.const_get(:PID_FILE) && pid_file_present)
    end
    allow(Process).to receive(:spawn).and_return(42)
    allow(Process).to receive(:detach)
    allow(Process).to receive(:kill).with(0, 42).and_raise(Errno::ESRCH)

    load_script

    expect(catch(:service_exit) { runner.start }).to eq(1)
    expect(warnings).to include("bin/service: failed to start (pid 42 exited). See #{Object.const_get(:LOG_FILE)}.")
    expect(warnings).to include("Recent log output:")
    expect(warnings).to include("simulated startup error\n")
    expect(File).to have_received(:delete).with(Object.const_get(:PID_FILE))
  end

  it "waits for /up to answer, not just for the process to survive" do
    load_script
    allow(runner).to receive(:running_pid).and_return(nil)
    allow(FileUtils).to receive(:mkdir_p)
    allow(File).to receive(:open).and_return(StringIO.new)
    allow(File).to receive(:write)
    allow(Process).to receive(:spawn).and_return(42)
    allow(Process).to receive(:detach)
    allow(Process).to receive(:kill).with(0, 42).and_return(1)
    allow(runner).to receive(:sleep)
    answers = [ false, false, true ]
    allow(runner).to receive(:up?) { answers.shift }

    runner.start

    expect(runner).to have_received(:up?).at_least(3).times
    expect(output.last).to include("started (pid 42), answering on http://127.0.0.1:")
  end

  it "fails when the process stays up but never answers /up" do
    load_script
    allow(runner).to receive(:running_pid).and_return(nil)
    allow(FileUtils).to receive(:mkdir_p)
    allow(File).to receive(:open).and_return(StringIO.new)
    allow(File).to receive(:write)
    allow(Process).to receive(:spawn).and_return(42)
    allow(Process).to receive(:detach)
    allow(Process).to receive(:kill).with(0, 42).and_return(1)
    allow(runner).to receive(:up?).and_return(false)
    now = Time.now
    allow(Time).to receive(:now).and_return(now, now + Object.const_get(:STARTUP_TIMEOUT) + 1)

    expect(catch(:service_exit) { runner.start }).to eq(1)
    expect(warnings.last).to include("pid 42 is running but http://127.0.0.1:", "/up did not answer")
  end

  it "runs the preflight before restarting, and leaves the running instance alone when it fails" do
    load_script
    calls = []
    allow(runner).to receive(:system) { |*args, **| calls << args and false }
    allow(runner).to receive(:stop) { calls << :stop }
    allow(runner).to receive(:start) { calls << :start }

    expect(catch(:service_exit) { runner.run_command([ "restart" ]) }).to eq(1)

    expect(calls).to eq([ [ File.join(Object.const_get(:ROOT_DIR), "bin/preflight"), "--prod-copy" ] ])
    expect(warnings.last).to include("preflight failed, so the running instance was left alone")
  end

  it "restarts once the preflight passes, and skips it on request" do
    load_script
    calls = []
    allow(runner).to receive(:system) { |*args, **| calls << :preflight and true }
    allow(runner).to receive(:stop) { calls << :stop }
    allow(runner).to receive(:start) { calls << :start }

    runner.run_command([ "restart" ])
    runner.run_command([ "restart", "--skip-preflight" ])

    expect(calls).to eq([ :preflight, :stop, :start, :stop, :start ])
  end
end
