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
      persist_codex_cli_session_id(worker)
      persist_claude_final_response(worker)
      stop_reason = worker.stop_reason.presence || stop_reason_for(worker, exit_code, output)
      worker.update!(
        status: "stopped",
        stopped_at: Time.current,
        exit_code: exit_code,
        stop_reason:,
        **usage
      )
      capacity_failure = Orchestrator::CapacityFailure.detected?(output) && worker.handoff_completed_at.blank?

      if worker.role == "chaperone"
        handle_chaperone_worker_stop(worker) unless capacity_failure
        block_run_for_capacity!(worker, output) if capacity_failure
        next
      end

      if worker.role == "project_init"
        handle_project_init_worker_stop(worker) unless capacity_failure
        block_run_for_capacity!(worker, output) if capacity_failure
        next
      end

      review = record_failed_attempt(worker, stop_reason:, output:) unless capacity_failure || worker.handoff_completed_at.present?
      TickRunJob.perform_later unless capacity_failure || review
      block_run_for_capacity!(worker, output) if capacity_failure
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

  # Codex never receives an incoming session id (unlike claude, which mints
  # one up front at spawn time -- see Orchestrator::WorkerSpawner) so it can
  # only be captured after the fact, from the worker's own log, once it's
  # actually run. update_column rather than folding into the update! a few
  # lines below deliberately keeps this independent of that call's own
  # attribute set.
  def persist_codex_cli_session_id(worker)
    return unless worker.command == "codex"
    return if worker.cli_session_id.present?

    session_id = Orchestrator::LogReader.codex_session_id(worker.log_path)
    worker.update_column(:cli_session_id, session_id) if session_id.present?
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def persist_claude_final_response(worker)
    return unless worker.command == "claude"

    response = Orchestrator::LogReader.claude_final_response(worker.log_path)
    return if response.blank?

    File.write(worker.last_message_path, "#{response.rstrip}\n")
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def stop_reason_for(worker, exit_code, output)
    return project_init_stop_reason(worker, exit_code) if worker.role == "project_init"
    return "Worker exited successfully after completing its handoff." if worker.handoff_completed_at.present? && exit_code == 0
    return "Worker exited with status #{exit_code} after completing its handoff." if worker.handoff_completed_at.present? && exit_code.present?
    return "Worker stopped after completing its handoff." if worker.handoff_completed_at.present?
    capacity_message = Orchestrator::CapacityFailure.stop_reason_message(output)
    return capacity_message if capacity_message
    return "Worker exited with status #{exit_code} before completing its handoff." if exit_code.present?

    "Process no longer running (detected by Rails reconciliation, exit status unavailable)."
  end

  # project_init never calls worker_turn (see handle_project_init_worker_stop),
  # so handoff_completed_at is never set even on a full success -- the
  # generic handoff-based messages above would misreport a successful run
  # as having stopped "before completing its handoff". Use the same
  # completion signal handle_project_init_worker_stop uses instead.
  def project_init_stop_reason(worker, exit_code)
    if project_init_completed?(worker)
      "Project setup discovery completed and recorded its findings."
    elsif exit_code.present?
      "Project setup discovery exited with status #{exit_code} without recording its findings."
    else
      "Process no longer running (detected by Rails reconciliation, exit status unavailable)."
    end
  end

  def project_init_completed?(worker)
    worker.run.workspace.workspace_memory_entries.current.exists?(
      entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY
    )
  end

  def record_failed_attempt(worker, stop_reason:, output:)
    request = SpawnRequest.find_by(fulfilled_worker_id: worker.worker_id)
    return unless request
    return if StepAttempt.exists?(worker_id: worker.worker_id)

    attempt = StepAttempt.create!(
      run: worker.run, spawn_request: request, worker_id: worker.worker_id,
      lineage_key: request.lineage_key.presence || request.scope,
      mode: worker.execution_mode.presence || Orchestrator::SpawnRequestedWorkers.execution_mode(request).presence || "unknown",
      outcome: "failed", result: "#{stop_reason}\n#{output}".strip,
      evidence_citations: []
    )
    # A failed verification attempt is recovered by Rails re-requesting a
    # real verifier (see Orchestrator::VerifierRecovery) -- routing it to
    # chaperone/planner recovery is structurally doomed, since a planner
    # cannot dispatch verifier-role work. VerifierRecovery publishes its
    # own phase; returning nil lets the caller tick immediately so the
    # fresh verifier request dispatches. It can still hand back a
    # ChaperoneReview (criterion no longer awaiting verification), which
    # then follows the normal chaperone announcement below.
    if Orchestrator::VerifierRecovery.applicable?(attempt)
      outcome = Orchestrator::VerifierRecovery.call(attempt)
      return nil unless outcome.is_a?(ChaperoneReview)

      review = outcome
    else
      review = Orchestrator::ChaperoneTrigger.call(attempt)
    end
    if review
      worker.run.publish_phase!(
        phase: "planning", owner: "chaperone",
        summary: "Chaperone is reviewing repeated worker failures for #{attempt.lineage_key}."
      )
    end
    review
  end

  # A chaperone review is never itself the subject of another chaperone
  # review (record_failed_attempt/ChaperoneTrigger is intentionally skipped
  # by the caller's `next`) -- chaperone failure escalates immediately via
  # handle_review_failure, same as today; running the normal retry/chaperone
  # path here would recursively spawn chaperone-reviewing-chaperone.
  def handle_chaperone_worker_stop(worker)
    request = SpawnRequest.find_by(fulfilled_worker_id: worker.worker_id)
    return unless request

    review = ChaperoneReview.find_by(run_id: worker.run_id, lineage_key: request.lineage_key, status: %w[queued running])
    return unless review

    review.update!(status: "failed", summary: worker.stop_reason, completed_at: Time.current)
    Orchestrator::ApplyChaperoneDecision.handle_review_failure(review: review)
  end

  # Whether the process died from success, a crash, or a bad discovery, the
  # only thing that matters is whether the primary fact now exists -- that
  # single check is both the completion signal and the idempotency guard
  # (see Orchestrator::ProjectInitTrigger). A miss reuses the exact same
  # failed-attempt/chaperone escalation path every other worker role
  # already gets. A success needs no further bookkeeping for a normal task
  # run's own project_init request, but Orchestrator::WorkspaceInit's
  # dedicated bootstrap run has no planner watching it (deliberately -- see
  # that module's comment), so nothing else will ever end it; resolve it
  # here instead of leaving it to sit "running" and eventually trip
  # TickRunJob's stalled-worker recovery into re-planning the same
  # discovery from scratch.
  def handle_project_init_worker_stop(worker)
    unless project_init_completed?(worker)
      output = Orchestrator::LogReader.read_tail_lines(worker.log_path, 12).to_s
      record_failed_attempt(worker, stop_reason: worker.stop_reason, output:)
      return
    end

    complete_bootstrap_run!(worker.run) if bootstrap_run?(worker.run)
  end

  def bootstrap_run?(run)
    run.launched_by == "workspace_init"
  end

  def complete_bootstrap_run!(run)
    return unless run.status.in?(Run::NON_TERMINAL_STATUSES)

    if run.workspace.initialized?
      run.update!(status: "completed", stopped_at: Time.current)
      run.publish_phase!(phase: "completed", owner: "orchestrator", summary: "Workspace initialization complete.")
    else
      run.update!(status: "stopped", stopped_at: Time.current)
      run.publish_phase!(
        phase: "awaiting_user_feedback", owner: "orchestrator",
        summary: "Dev environment recorded, but protected paths were not declared. Re-run project setup to retry."
      )
    end
  end

  def block_run_for_capacity!(worker, output)
    retry_at = capacity_reset_at(output)
    run = worker.run
    return unless run

    run.update!(capacity_available_at: retry_at)
    run.publish_phase!(
      phase: "waiting_on_capacity",
      owner: "orchestrator",
      summary: "#{run.launcher_variant.capitalize} capacity limit reached; retrying after #{retry_at.in_time_zone.strftime('%H:%M %Z')}."
    )
  end

  def capacity_reset_at(output)
    Orchestrator::CapacityFailure.reset_at(output)
  end
end
