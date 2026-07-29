require "spec_helper"
require "fileutils"
require "stringio"

RSpec.describe "bin/service" do
  it "reports the log when the production child exits immediately" do
    warnings = []
    runner = Object.new
    script = File.expand_path("../../bin/service", __dir__)
    pid_file_present = false

    runner.define_singleton_method(:warn) { |message| warnings << message }
    runner.define_singleton_method(:exit) { |status| throw :startup_exit, status }

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

    script_source = File.read(script).split("\ncase ARGV.first", 2).first
    eval(script_source, runner.instance_eval { binding }, script)

    expect(catch(:startup_exit) { runner.start }).to eq(1)
    expect(warnings).to include("bin/service: failed to start (pid 42 exited). See #{Object.const_get(:LOG_FILE)}.")
    expect(warnings).to include("Recent log output:")
    expect(warnings).to include("simulated startup error\n")
    expect(File).to have_received(:delete).with(Object.const_get(:PID_FILE))
  end
end
