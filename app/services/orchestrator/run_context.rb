require "pathname"

module Orchestrator
  # Compiles curated, current operational knowledge for one run. It is kept
  # separate from the unbounded event log so planners receive decisions and
  # acceptance gates without replaying every worker transcript.
  #
  # Acceptance criteria are not handled here -- see Orchestrator::AcceptanceCriteria,
  # which owns that whole lifecycle as its own first-class model rather than a
  # RunContextEntry kind. This module covers the other four kinds only.
  module RunContext
    module_function

    DEFAULT_BRIEF_ENTRY_LIMIT = 8
    BRIEF_CONTENT_LIMIT = 600
    DETAIL_ENTRY_LIMIT = 20
    AVAILABLE_KEY_LIMIT = 50

    # The default snapshot is deliberately a small briefing, not a replay of
    # the whole run. Agents can request exact entry keys when a fact needs
    # its full evidence or wording. Keeping the default bounded prevents a
    # new agent from spending its context window on history it may not need.
    def snapshot(run_id:, entry_keys: nil)
      entries = RunContextEntry.where(run_id: run_id).order(:kind, :entry_key)
      selected_entries = select_entries(entries.to_a, entry_keys)
      artifact_metadata = collect_artifact_metadata(run_id)

      {
        run_id: run_id,
        context_mode: entry_keys.present? ? "selected" : "brief",
        entries: selected_entries,
        available_entry_keys: entries.limit(AVAILABLE_KEY_LIMIT).pluck(:entry_key),
        available_entry_count: entries.count,
        artifacts: artifact_metadata,
        retrieval_hint: "Request entryKeys for full details only when a specific fact, decision, or evidence reference is needed."
      }
    end

    def upsert!(run_id:, entry_key:, kind:, status:, content:, evidence_ref:, created_by:)
      entry = RunContextEntry.find_or_initialize_by(run_id: run_id, entry_key: entry_key)
      entry.assign_attributes(
        kind: kind,
        status: status,
        content: content,
        evidence_ref: evidence_ref.presence,
        created_by: created_by
      )
      entry.save!
      entry
    end

    def validate_evidence!(run_id:, evidence_ref:)
      run = Run.find_by!(run_id:)
      root = Pathname.new(run.target_root).expand_path
      candidate = root.join(evidence_ref.to_s).cleanpath
      inside_workspace = candidate.to_s == root.to_s || candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
      workspace_evidence = inside_workspace && candidate.file?
      artifact_evidence = begin
        File.file?(ArtifactStore.resolve_path(run.target_root, run.run_id, evidence_ref))
      rescue ArgumentError
        false
      end
      raise ArgumentError, "Verified acceptance evidence does not exist: #{evidence_ref}" unless workspace_evidence || artifact_evidence
    end

    def collect_artifact_metadata(run_id)
      run = Run.find_by(run_id: run_id)
      return [] unless run

      all_names = ArtifactStore.names(run.target_root, run_id)
      metadata_result = ArtifactStore.collect(run.target_root, run_id, all_names)

      build_artifact_info(run_id, metadata_result[:artifacts])
    end
    private_class_method :collect_artifact_metadata

    def build_artifact_info(run_id, artifacts_metadata)
      workers_by_artifact = build_producer_map(run_id)

      artifacts_metadata.map do |metadata|
        info = {
          name: metadata[:name],
          exists: metadata[:exists],
          sizeBytes: metadata[:size_bytes],
          updatedAt: metadata[:updated_at]
        }

        producer = workers_by_artifact[metadata[:name]]
        info[:producedBy] = producer if producer

        info[:inherited] = is_inherited?(run_id, metadata[:name])

        info
      end
    end
    private_class_method :build_artifact_info

    def build_producer_map(run_id)
      map = {}
      Worker.where(run_id: run_id, status: "stopped").each do |worker|
        next unless worker.produced_artifacts.is_a?(Array)

        worker.produced_artifacts.each do |artifact_name|
          map[artifact_name] = worker.worker_id
        end
      end
      map
    end
    private_class_method :build_producer_map

    def is_inherited?(run_id, artifact_name)
      Worker.where(run_id: run_id, status: "stopped")
        .where("inherited_artifacts LIKE ?", "%\"#{artifact_name}\"%")
        .exists?
    end
    private_class_method :is_inherited?

    def select_entries(entries, entry_keys)
      if entry_keys.present?
        entries.select { |entry| entry_keys.include?(entry.entry_key) }
          .first(DETAIL_ENTRY_LIMIT)
          .map(&:as_json)
      else
        entries
          .sort_by { |entry| [ brief_kind_rank(entry.kind), -entry.updated_at.to_i ] }
          .first(DEFAULT_BRIEF_ENTRY_LIMIT)
          .map { |entry| brief_entry(entry) }
      end
    end
    private_class_method :select_entries

    def brief_kind_rank(kind)
      %w[operator_decision constraint fact rejected_approach].index(kind) || 99
    end
    private_class_method :brief_kind_rank

    def brief_entry(entry)
      entry.as_json.merge(content: truncate(entry.content, BRIEF_CONTENT_LIMIT))
    end
    private_class_method :brief_entry

    def truncate(value, limit)
      text = value.to_s
      text.length > limit ? "#{text.first(limit).rstrip}…" : text
    end
    private_class_method :truncate
  end
end
