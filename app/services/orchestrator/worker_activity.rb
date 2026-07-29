module Orchestrator
  # View-facing worker state. The worker registry remains the source of truth;
  # this only adds bounded, local filesystem observations for the ops UI.
  class WorkerActivity
    def self.for_workers(workers)
      assignments = SpawnRequest.where(fulfilled_worker_id: workers.map(&:worker_id)).index_by(&:fulfilled_worker_id)
      workers.map { |worker| new(worker, assignment: assignments[worker.worker_id]).as_json.merge(entry_type: :worker) }
        .sort_by { |activity| [ activity[:sort_rank], activity_sort_key(activity) ] }
    end

    def self.for_planner_entries(planner_activities, decisions)
      (planner_activities + decisions.map { |decision| planner_decision_entry(decision) }).sort_by do |entry|
        activity_sort_key(entry)
      end
    end

    def self.activity_sort_key(entry)
      -(entry[:at]&.to_f || 0)
    end
    private_class_method :activity_sort_key

    def self.worker_sort_key(activity)
      [ activity[:sort_rank] || 2, activity_sort_key(activity) ]
    end
    private_class_method :worker_sort_key

    def self.planner_decision_entry(decision)
      {
        entry_type: :planner_decision,
        role: "planner",
        worker: nil,
        decision: decision,
        at: decision.created_at,
        last_activity_at: decision.created_at
      }
    end

    def initialize(worker, assignment: nil)
      @worker = worker
      @assignment = assignment
    end

    def as_json
      {
        worker: @worker,
        role: @worker.role,
        display_status: display_status,
        status_label: status_label,
        attention_needed: attention_needed?,
        last_activity_at: last_activity_at,
        output_preview: output_preview,
        output_source: output_source,
        progress_updates: progress_updates,
        latest_progress: progress_updates.last,
        at: last_activity_at,
        log_available: File.file?(@worker.log_path),
        started_at: @worker.started_at,
        stopped_at: @worker.stopped_at,
        sort_rank: sort_rank,
        assignment_text: @assignment&.text,
        assignment_context: @assignment&.context,
        assignment_lineage_key: @assignment&.lineage_key
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
        log = Orchestrator::LogReader.read_full_content(@worker.log_path)[:content]
        if log.present?
          @output_source = "Full worker log"
          [ Orchestrator::LogReader.format_for_display(log), read_file(@worker.last_message_path) ].compact_blank.join("\n")
        else
          read_last_message
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

    def read_last_message
      message = read_file(@worker.last_message_path)
      return unless message.present?

      @output_source = "Latest agent message (worker log unavailable)"
      message
    end

    def file_mtime(path)
      File.mtime(path) if File.file?(path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
