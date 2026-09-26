class BackgroundJobHealth
  READY_JOB_STALE_AFTER = 20.seconds
  HEARTBEAT_STALE_AFTER = 30.seconds
  RELEVANT_JOB_CLASSES = %w[RunDispatchJob StartRunSessionJob StopRunJob RunSessionReconcileJob].freeze

  def self.warning
    new.warning
  end

  def warning
    return nil unless solid_queue_active?

    stale_ready_jobs = ready_jobs_scope.where("solid_queue_ready_executions.created_at <= ?", READY_JOB_STALE_AFTER.ago)
    return nil if stale_ready_jobs.empty?
    return nil if worker_heartbeat_fresh?

    job_counts = stale_ready_jobs.joins(:job).group("solid_queue_jobs.class_name").count
    summary = job_counts.map { |class_name, count| "#{count} #{class_name}" }.join(", ")

    "Background jobs are queued but no Solid Queue worker heartbeat is active. " \
      "Pending work: #{summary}. Start `bin/jobs` or `bin/dev`."
  rescue ActiveRecord::StatementInvalid
    nil
  end

  private

  def solid_queue_active?
    Rails.configuration.active_job.queue_adapter == :solid_queue &&
      defined?(SolidQueue::ReadyExecution) &&
      defined?(SolidQueue::Process)
  end

  def ready_jobs_scope
    SolidQueue::ReadyExecution.joins(:job).where(solid_queue_jobs: { class_name: RELEVANT_JOB_CLASSES })
  end

  def worker_heartbeat_fresh?
    SolidQueue::Process.where("last_heartbeat_at >= ?", HEARTBEAT_STALE_AFTER.ago).exists?
  end
end
