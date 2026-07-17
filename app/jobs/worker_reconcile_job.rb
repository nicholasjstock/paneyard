# Periodic liveness check for every Worker row still marked "running".
# A worker's spawning process (TickRunJob, or that worker's own MCP
# client, depending on which path recorded it) might not notice its
# exit -- Rails can independently confirm liveness the same way
# StopRunJob/Orchestrator::WorkerSpawner already do (Process.kill(0, pid)
# works fine for a process this Rails instance didn't fork, same host).
#
# This is a redundant safety net, not the primary detection path. Losing
# exact exit-code fidelity for a Rails-detected-only stop is an
# acceptable, already-anticipated degradation -- Worker#stop_reason
# already treats this as best-effort.
class WorkerReconcileJob < ApplicationJob
  queue_as :default

  def perform
    Worker.active.find_each do |worker|
      next if process_alive?(worker.pid)

      exit_code = read_exit_code(worker.exit_status_path)
      output = Orchestrator::LogReader.read_tail_lines(worker.log_path, 12).to_s
      usage = Orchestrator::LogReader.claude_usage(worker.log_path)
      worker.update!(
        status: "stopped",
        stopped_at: Time.current,
        exit_code: exit_code,
        stop_reason: worker.stop_reason.presence || stop_reason_for(worker, exit_code, output),
        **usage
      )
      block_run_for_capacity!(worker, output) if claude_capacity_failure?(output)
    end
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def read_exit_code(path)
    return unless path.present? && File.file?(path)

    value = File.read(path).strip
    Integer(value, 10) if value.match?(/\A\d+\z/)
  rescue Errno::ENOENT, Errno::EACCES, ArgumentError
    nil
  end

  def stop_reason_for(worker, exit_code, output)
    return "Claude session limit reached; worker exited before completing its handoff." if output.match?(/hit your session limit/i)
    return "Claude rate limit reached; worker exited before completing its handoff." if output.match?(/rate limit|too many requests/i)
    return "Worker exited with status #{exit_code} before completing its handoff." if exit_code.present?

    "Process no longer running (detected by Rails reconciliation, exit status unavailable)."
  end

  def claude_capacity_failure?(output)
    output.match?(/hit your session limit|rate limit|too many requests/i)
  end

  def block_run_for_capacity!(worker, output)
    retry_at = capacity_reset_at(output)
    run = worker.run
    return unless run

    run.update!(capacity_available_at: retry_at)
    run.publish_phase!(
      phase: "waiting_on_capacity",
      owner: "orchestrator",
      summary: "Claude capacity limit reached; retrying after #{retry_at.in_time_zone.strftime('%H:%M %Z')}."
    )
  end

  def capacity_reset_at(output)
    match = output.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\(([^)]+)\)/i)
    return 30.minutes.from_now unless match

    hour = match[1].to_i
    minute = match[2].to_i
    meridiem = match[3]&.downcase
    hour = (hour % 12) + (meridiem == "pm" ? 12 : 0) if meridiem.present?
    zone = Time.find_zone(match[4]) || Time.zone
    now = Time.current.in_time_zone(zone)
    retry_at = zone.local(now.year, now.month, now.day, hour, minute)
    retry_at += 1.day if retry_at <= Time.current
    retry_at
  end
end
