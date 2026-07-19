module Orchestrator
  # View-facing worker state. The worker registry remains the source of truth;
  # this only adds bounded, local filesystem observations for the ops UI.
  class WorkerActivity
    PREVIEW_MAX_CHARS = 600
    RAW_TAIL_LINES = 120
    DISPLAY_TAIL_LINES = 6

    def self.for_workers(workers)
      workers.map { |worker| new(worker).as_json }
        .sort_by { |activity| [ activity[:sort_rank], -(activity[:started_at]&.to_i || 0) ] }
    end

    def initialize(worker)
      @worker = worker
    end

    def as_json
      {
        worker: @worker,
        display_status: display_status,
        status_label: status_label,
        attention_needed: attention_needed?,
        last_activity_at: last_activity_at,
        output_preview: output_preview,
        output_source: output_source,
        progress_updates: progress_updates,
        latest_progress: progress_updates.last,
        log_available: File.file?(@worker.log_path),
        started_at: @worker.started_at,
        stopped_at: @worker.stopped_at,
        sort_rank: sort_rank
      }
    end

    private

    def display_status
      return "running" if @worker.status == "running"

      attention_needed? ? "attention" : "stopped"
    end

    def status_label
      return "running" if @worker.status == "running"

      attention_needed? ? "needs attention" : "stopped"
    end

    def attention_needed?
      @worker.status == "stopped" && @worker.stop_reason.to_s.match?(/process no longer running|unexpected|crash|error/i)
    end

    def sort_rank
      return 0 if @worker.status == "running"
      return 1 if attention_needed?

      2
    end

    def last_activity_at
      [ @worker.started_at, @worker.stopped_at, file_mtime(@worker.log_path), file_mtime(@worker.last_message_path) ].compact.max
    end

    def output_preview
      @output_preview ||= begin
        message = read_file(@worker.last_message_path)
        if message.present?
          @output_source = "Latest agent message"
          truncate(message)
        else
          tail = Orchestrator::LogReader.read_tail_lines(@worker.log_path, RAW_TAIL_LINES)
          if tail.present?
            @output_source = "Latest log output"
            truncate(display_tail(Orchestrator::LogReader.format_for_display(tail)))
          end
        end
      end
    end

    attr_reader :output_source

    def progress_updates
      @progress_updates ||= Orchestrator::LogReader.progress_updates(@worker.log_path)
    end

    def read_file(path)
      return unless File.file?(path)

      File.read(path).to_s.force_encoding("UTF-8").scrub
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def file_mtime(path)
      File.mtime(path) if File.file?(path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def truncate(text)
      text.length > PREVIEW_MAX_CHARS ? "#{text.first(PREVIEW_MAX_CHARS).rstrip}\n..." : text
    end

    def display_tail(text)
      text.lines.last(DISPLAY_TAIL_LINES).join
    end
  end
end
