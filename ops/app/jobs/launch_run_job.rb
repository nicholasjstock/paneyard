# Starts a brand-new orchestrator run: seeds the initial planner request on
# the bus, then Process.spawns the bin/supervisor_launcher(_claude) tick
# loop as its own OS process (not managed by Node at all -- nothing on the
# Node side tracks "which process drives run X", so this job is the only
# place that mapping gets recorded, onto the Run row itself).
#
# Runs via ActiveJob (not inline in the controller) so the web request
# stays fast and a failed spawn is visible/retryable like any other job.
class LaunchRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    target_root = run.target_root

    run.spawn_requests.create!(
      asked_by: run.launched_by.presence || "ops_hub",
      scope: "workflow-plan.md",
      text: run.task,
      requested_role: "planner",
      priority: "blocking",
      tags: %w[ops-hub launch]
    )

    log_dir = Rails.root.join("log", "runs")
    FileUtils.mkdir_p(log_dir)
    log_path = log_dir.join("#{run.run_id}.log").to_s

    orchestrator_root = Rails.application.config.x.orchestrator_root
    launcher_bin = run.launcher_variant == "claude" ? "bin/supervisor_launcher_claude" : "bin/supervisor_launcher"
    command = [ File.join(orchestrator_root, launcher_bin), "--run-id=#{run.run_id}", "--task=#{run.task}" ]
    command << "--scenario=#{run.scenario}" if run.scenario.present?
    command << "--frontend-url=#{run.frontend_url}" if run.frontend_url.present?

    # Brakeman flags this Process.spawn call (command injection) and the
    # log path above (file access) because run.task/scenario/frontend_url
    # are user-supplied. Both are safe as written: Process.spawn is given
    # an argv array, not a single interpolated shell string, so it execs
    # bin/supervisor_launcher* directly with no shell involved -- no
    # metacharacter can escape its argument boundary (confirmed the
    # downstream bash script forwards args via quoted "$@" and the
    # TypeScript arg parser treats each value as an opaque string, never
    # re-evaluated). run_id in the log path is never user input --
    # RunsController#run_params doesn't permit it; it's always this job's
    # own server-generated demo-<timestamp>-<hex> value.
    log_file = File.open(log_path, "a")
    pid = Process.spawn(
      {
        "WORKFLOW_TARGET_ROOT" => target_root,
        "WORKFLOW_STATE_BACKEND" => "rails",
        "WORKFLOW_RAILS_URL" => ENV.fetch("WORKFLOW_RAILS_URL", "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}")
      },
      *command,
      chdir: orchestrator_root,
      pgroup: true,
      out: log_file,
      err: log_file,
      in: File::NULL
    )
    Process.detach(pid)

    run.update!(
      supervisor_pid: pid,
      status: "running",
      started_at: Time.current,
      log_path: log_path
    )
  rescue => e
    run&.update!(status: "failed")
    raise
  ensure
    log_file&.close
  end
end
