class WorkersController < ApplicationController
  before_action :require_workspace

  # Mirrors scripts/workflow-mcp-http.ts's now-retired /workers/:id/log
  # endpoint's defaults.
  DEFAULT_TAIL_LINES = 120

  def index
    @workers = workspace_workers.order(started_at: :desc).map { |worker| JSON.parse(worker.to_json) }
  end

  def show
    @worker_id = params[:id]
    worker = workspace_workers.find_by(worker_id: @worker_id)

    if worker
      @log = build_log_payload(worker)
    else
      @log = nil
      @orchestrator_error = "Worker not found: #{@worker_id}"
    end
  end

  def stop
    worker = workspace_workers.find_by!(worker_id: params[:id])
    if worker.status == "running"
      begin
        Process.kill("SIGTERM", worker.pid) if process_alive?(worker.pid)
      rescue Errno::ESRCH
        nil
      end
      worker.update!(status: "stopped", stopped_at: Time.current, stop_reason: stop_reason)
    end
    redirect_back fallback_location: workspace_workers_path(current_workspace), notice: "Worker stopped."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: workspace_workers_path(current_workspace), alert: "Failed to stop worker: unknown worker #{params[:id]}"
  end

  private

  def workspace_workers
    Worker.joins(:run).where(runs: { workspace_id: current_workspace.id })
  end

  def build_log_payload(worker)
    full = Orchestrator::LogReader.read_full_content(worker.log_path)
    last_message = File.exist?(worker.last_message_path) ? File.read(worker.last_message_path) : nil

    {
      "workerId" => worker.worker_id,
      "runId" => worker.run_id,
      "role" => worker.role,
      "nickname" => worker.nickname,
      "status" => worker.status,
      "logPath" => worker.log_path,
      "lastMessagePath" => worker.last_message_path,
      "startedAt" => worker.started_at&.iso8601(3),
      "stoppedAt" => worker.stopped_at&.iso8601(3),
      "stopReason" => worker.stop_reason,
      "tail" => Orchestrator::LogReader.format_for_display(Orchestrator::LogReader.read_tail_lines(worker.log_path, DEFAULT_TAIL_LINES)),
      "lastMessage" => last_message,
      "logContent" => Orchestrator::LogReader.format_for_display(full[:content]),
      "logTruncated" => full[:truncated],
      "logTotalBytes" => full[:total_bytes]
    }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def stop_reason
    params[:reason].presence || "manually stopped from ops hub"
  end
end
