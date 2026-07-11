require "shellwords"
require "timeout"
require "tmpdir"

module FakeAgentHarness
  def with_fake_agents
    Dir.mktmpdir("workflow-fake-agents") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)

      %w[claude codex].each do |name|
        wrapper_path = File.join(bin_dir, name)
        script_path = Rails.root.join("spec/support/fake_agent_process.rb")
        File.write(wrapper_path, wrapper_script(name: name, script_path: script_path))
        FileUtils.chmod("+x", wrapper_path)
      end

      original_path = ENV["PATH"]
      original_root = ENV["WORKFLOW_FAKE_AGENT_APP_ROOT"]
      original_env = ENV["WORKFLOW_FAKE_AGENT_RAILS_ENV"]

      ENV["PATH"] = "#{bin_dir}:#{original_path}"
      ENV["WORKFLOW_FAKE_AGENT_APP_ROOT"] = Rails.root.to_s
      ENV["WORKFLOW_FAKE_AGENT_RAILS_ENV"] = Rails.env

      yield
    ensure
      ENV["PATH"] = original_path
      ENV["WORKFLOW_FAKE_AGENT_APP_ROOT"] = original_root
      ENV["WORKFLOW_FAKE_AGENT_RAILS_ENV"] = original_env
    end
  end

  def wait_until(timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        result = yield
        return result if result

        sleep 0.05
      end
    end
  end

  private

  def wrapper_script(name:, script_path:)
    <<~SH
      #!/bin/sh
      export WORKFLOW_FAKE_AGENT_VARIANT=#{name}
      exec ruby #{Shellwords.escape(script_path.to_s)} "$@"
    SH
  end
end

RSpec.configure do |config|
  config.include FakeAgentHarness
end
