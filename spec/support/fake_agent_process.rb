#!/usr/bin/env ruby

require "fileutils"
require "json"
require "timeout"

module FakeAgentProcess
  module_function

  def run!(argv:, stdin:)
    app_root = ENV.fetch("WORKFLOW_FAKE_AGENT_APP_ROOT")
    Dir.chdir(app_root)
    ENV["BUNDLE_GEMFILE"] ||= File.join(app_root, "Gemfile")
    ENV["RAILS_ENV"] ||= ENV.fetch("WORKFLOW_FAKE_AGENT_RAILS_ENV", "test")
    ENV["DATABASE_URL"] ||= "sqlite3:#{File.join(app_root, 'storage', 'test.sqlite3')}"
    require File.join(app_root, "config/environment")

    prompt = read_prompt(argv: argv, stdin: stdin)
    run_id = prompt[/Run (.+?)\. Bus request:/m, 1] || raise("Missing run id in prompt: #{prompt.inspect}")
    role = detect_role(argv: argv, prompt: prompt)
    scope = prompt[/Bus request: (.+?)\. Requested by:/m, 1] || "workflow-plan.md"

    worker = find_worker(run_id: run_id, role: role)
    append_log(worker.log_path, "[fake-agent] starting role=#{role} run_id=#{run_id} scope=#{scope}") if worker
    File.write(worker.last_message_path, "fake #{role} handled #{scope}\n") if worker

    McpTools::PublishRunStatusTool.call(
      runId: run_id,
      phase: role == "planner" ? "planning" : "working",
      owner: role,
      summary: "Fake #{role} processed #{scope}.",
      server_context: nil
    )

    if role == "planner"
      McpTools::WriteWorkflowArtifactTool.call(
        runId: run_id,
        artifactName: scope,
        content: "# Fake plan\n\nProcessed #{scope} for #{run_id}.\n",
        server_context: nil
      )
      McpTools::PlannerTurnTool.call(
        runId: run_id,
        summary: "Fake planner completed the run.",
        nextStep: nil,
        followingSteps: [],
        server_context: nil
      )
    else
      worker ||= wait_for_worker(run_id: run_id, role: role)
      McpTools::WriteWorkflowArtifactTool.call(
        runId: run_id,
        artifactName: scope,
        content: "# Fake artifact\n\nCompleted #{scope} for #{run_id}.\n",
        server_context: nil
      )
      McpTools::WorkerTurnTool.call(
        runId: run_id,
        role: role,
        nickname: worker.nickname,
        scope: scope,
        result: "Fake #{role} completed #{scope}.",
        task: worker.reason,
        server_context: nil
      )
    end

    append_log(worker.log_path, "[fake-agent] completed role=#{role} run_id=#{run_id} scope=#{scope}") if worker
  end

  def find_worker(run_id:, role:)
    Worker.where(run_id: run_id, role: role).order(:created_at).last
  end

  def read_prompt(argv:, stdin:)
    if argv.include?("-p") && argv.include?("--")
      argv.last
    elsif argv.include?("--agent")
      argv.last
    else
      stdin.read
    end
  end

  def detect_role(argv:, prompt:)
    if (index = argv.index("--agent"))
      argv.fetch(index + 1)
    else
      prompt[/Target role: ([^.]+)\./, 1] || "worker"
    end
  end

  def wait_for_worker(run_id:, role:)
    Timeout.timeout(5) do
      loop do
        worker = find_worker(run_id: run_id, role: role)
        return worker if worker
        sleep 0.05
      end
    end
  end

  def append_log(path, line)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{line}\n", mode: "a")
  end
end

FakeAgentProcess.run!(argv: ARGV, stdin: $stdin) if ENV["WORKFLOW_FAKE_AGENT_APP_ROOT"] && !ENV["WORKFLOW_FAKE_AGENT_APP_ROOT"].empty?
