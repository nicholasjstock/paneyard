# Watches active worker log files and broadcasts only when a log advances.
# This is intentionally separate from the five-second orchestration tick: log
# output is an observation stream, not a planning decision.
class BroadcastWorkerLogsJob < ApplicationJob
  queue_as :default

  def perform
    Worker.active.includes(:run).find_each do |worker|
      updated_at = log_mtime(worker.log_path)
      next unless updated_at && (worker.log_updated_at.nil? || updated_at > worker.log_updated_at)

      worker.update_column(:log_updated_at, updated_at)
      Turbo::StreamsChannel.broadcast_refresh_to("worker_#{worker.worker_id}")
      Turbo::StreamsChannel.broadcast_refresh_to("run_#{worker.run_id}")
      Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{worker.run.workspace_id}_workers") if worker.run&.workspace_id.present?
    end
  end

  private

  def log_mtime(path)
    Time.at(File.mtime(path).to_i).utc
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end
end
