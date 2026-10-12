require "rails_helper"

RSpec.describe Orchestrator::Runner::Worktrees do
  it "bounds remote verification and reaps only the Git child it started when the deadline expires" do
    child_pid = nil
    allow(Open3).to receive(:popen3).and_wrap_original do |original, *_args, **_options, &block|
      original.call(RbConfig.ruby, "-e", "sleep 60", pgroup: true) do |input, output, errors, process|
        child_pid = process.pid
        block.call(input, output, errors, process)
      end
    end
    allow(Timeout).to receive(:timeout).with(15).and_raise(Timeout::Error)

    expect { described_class.remote_refs(Pathname("/unused"), "unused", "refs/heads/run") }
      .to raise_error(Orchestrator::Runner::Error, /Timed out verifying the pushed branch/)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  end
end
