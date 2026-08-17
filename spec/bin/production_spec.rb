require "spec_helper"
require "socket"

RSpec.describe "bin/production" do
  it "prepares the database before starting both production processes" do
    events = []
    probe = instance_double(TCPServer, close: nil)
    runner = Object.new

    runner.define_singleton_method(:system) do |*arguments, **options|
      events << [ :system, arguments, options ]
      true
    end
    runner.define_singleton_method(:trap) { |_signal| }
    allow(TCPServer).to receive(:new) do |*arguments|
      events << [ :port_probe, arguments ]
      probe
    end
    allow(Process).to receive(:spawn) do |*arguments|
      events << [ :spawn, arguments ]
      events.length
    end
    allow(Process).to receive(:wait).and_return(1)
    allow(Process).to receive(:kill)

    original_rails_env = ENV["RAILS_ENV"]
    script = File.expand_path("../../bin/production", __dir__)
    eval(File.read(script), runner.instance_eval { binding }, script)

    system_commands = events.filter_map { |event| event[1] if event.first == :system }
    expect(system_commands).to eq([ [ "bundle", "check" ], [ "./bin/rails", "db:prepare" ] ])
    expect(system_commands).not_to include([ "./bin/rails", "db:abort_if_pending_migrations" ])
    expect(events.count { |event| event.first == :spawn }).to eq(2)
    expect(events.index { |event| event.first == :spawn }).to be > events.index { |event| event[1] == [ "./bin/rails", "db:prepare" ] }
  ensure
    ENV["RAILS_ENV"] = original_rails_env
  end
end
