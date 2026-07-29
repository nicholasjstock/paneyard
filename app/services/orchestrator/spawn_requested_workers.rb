module Orchestrator
  # Ports scripts/supervisor-loop.ts's spawnRequestedWorkers -- the
  # claim-before-spawn race-avoidance loop. Dispatch is deliberately
  # single-flight per run: a run may have one executor (worker, verifier,
  # or chaperone) or one planner decision in flight, never several at once.
  # This keeps shared target resources such as ports, files, and browsers
  # safe until resource-aware concurrency is explicitly introduced.
  module SpawnRequestedWorkers
    module_function

    def call(run:)
      # The scheduler may have overlapping ticks. Lock the run across the
      # eligibility check and request claim so only one tick can turn an idle
      # run into active work.
      run.with_lock { call_locked(run: run) }
    end

    def call_locked(run:)
      run_id = run.run_id
      active_workers = Worker.where(run_id: run_id, status: "running").to_a
      current_workers = Worker.where(run_id: run_id).to_a

      # A spawned executor owns the entire run until it reports completion.
      # Do this before dismissing overlapping slots: queued work is valid,
      # merely waiting its turn.
      return [] if active_workers.any?

      # Planners run as Rails jobs rather than Worker rows, so they need the
      # same single-flight protection explicitly. An awaiting chaperone is
      # intentionally excluded: its chaperone request is the one allowed
      # successor while the planner waits for that review.
      return [] if PlannerDecision.where(run_id: run_id, status: %w[queued running]).exists?

      # A currently-running worker already claims its (role, scope) slot --
      # that claim is the source of truth, not the bus's request history.
      # Any other open request for the same slot is redundant with an
      # in-flight claim, so dismiss it now instead of leaving it open
      # forever.
      active_claim_keys = active_workers.map { |worker| [ worker.role, worker.scope ] }.to_set
      SpawnRequest.where(run_id: run_id, status: "open").find_each do |request|
        next unless request.requested_role.present?
        next unless active_claim_keys.include?([ request.requested_role, request.scope ])

        request.update!(
          status: "dismissed",
          dismissed_by: "tick_run_job",
          dismissal_note: "Superseded — an active worker already claims #{request.requested_role}/#{request.scope}."
        )
      end

      spawn_requests = collect_spawn_requests(run_id: run_id, active_workers: active_workers)
      spawned_workers = []

      spawn_requests.each do |request|
        role = request.requested_role
        if role == "planner"
          decision = PlannerDecision.find_or_initialize_by(spawn_request_id: request.request_id)
          decision.assign_attributes(run: run, spawn_request: request, status: "queued", error: nil, completed_at: nil)
          decision.save!
          request.update!(
            status: "fulfilled", fulfilled_by: "planner_decision_job", fulfilled_at: Time.current,
            fulfillment_note: "Queued bounded Rails-owned planner decision #{decision.decision_id}."
          )
          run.publish_phase!(
            phase: "planning", owner: "orchestrator",
            summary: "Preparing one bounded planner decision from current run evidence."
          )
          PlannerDecisionJob.perform_later(decision.id)
          next
        end

        if role == "chaperone"
          dispatch_chaperone_request(run: run, request: request)
          next
        end

        if role == "reply_received"
          dispatch_reply_received_request(run: run, request: request)
          next
        end

        # Validate required artifacts exist before spawning
        artifact_validation = validate_required_artifacts(run:, request:)
        if artifact_validation.is_a?(String)
          request.update!(
            status: "dismissed", dismissed_by: "artifact_validation",
            dismissal_note: artifact_validation
          )
          next
        end

        nickname = build_unique_nickname(build_worker_nickname(role), current_workers + spawned_workers)
        reason = "Bus request from #{request.asked_by} for #{request.scope}."
        prompt = build_requested_worker_prompt(run_id: run_id, request: request, run: run)
        worker_id = SecureRandom.uuid

        # Claim the (role, scope) slot before actually spawning the
        # worker -- spawning does real file I/O and launches a process,
        # which takes far longer than this one DB write.
        request.update!(
          status: "fulfilled", fulfilled_by: "tick_run_job", fulfilled_at: Time.current,
          fulfillment_note: "Spawned worker #{nickname} (#{role}).", fulfilled_worker_id: worker_id
        )

        begin
          effective_allowed_paths = allowed_paths(request, run:)
          working_root = working_root_for(request:, run:)
          worker = WorkerSpawner.spawn_worker(
            run: run, role: role, nickname: nickname, reason: reason, scope: request.scope, prompt: prompt,
            worker_id: worker_id, mode: execution_mode(request), write_scope: write_scope(request),
            allowed_paths: effective_allowed_paths, model_tier: request.model_tier, lineage_key: request.lineage_key,
            inherited_artifacts: request.inherited_artifacts || [], working_root:
          )
        rescue Orchestrator::TargetPreflight::Error => e
          request.update!(
            status: "dismissed", dismissed_by: "target_preflight",
            dismissal_note: "Worker #{nickname} was not launched: #{e.message}"
          )
          run.update!(status: "failed", stopped_at: Time.current)
          run.publish_phase!(phase: "failed", owner: "target_preflight", summary: e.message)
          next
        rescue => e
          # The claim promised a worker that never came into existence --
          # undo it so dependents don't wait forever on a workerId that
          # will never appear, and so the slot is free for a real retry.
          request.update!(
            status: "dismissed", dismissed_by: "tick_run_job",
            dismissal_note: "Claimed worker #{nickname} (#{role}) failed to spawn: #{e.message}"
          )
          raise
        end

        spawned_workers << worker
      end

      spawned_workers
    end
    private_class_method :call_locked

    def collect_spawn_requests(run_id:, active_workers:)
      active_keys = active_workers.map { |worker| [ worker.role, worker.scope ] }.to_set
      latest_by_key = {}

      SpawnRequest.where(run_id: run_id, status: "open").order(:created_at, :id).each do |request|
        next unless request.requested_role.present?

        key = [ request.requested_role, request.scope ]
        next if active_keys.include?(key)

        latest_by_key[key] = request
      end

      candidates = latest_by_key.values.sort_by { |request| [ request.created_at, request.id ] }

      # A queued/running chaperone review is an orchestration boundary: only
      # its chaperone may proceed, never unrelated worker requests behind it.
      if ChaperoneReview.where(run_id: run_id, status: %w[queued running]).exists?
        candidates.select! { |request| request.requested_role == "chaperone" }
      end

      # Same boundary for a queued/running reply_received review: the run is
      # blocked on classifying one specific reply, so nothing else may
      # dispatch ahead of it.
      if ReplyReceivedReview.where(run_id: run_id, status: %w[queued running]).exists?
        candidates.select! { |request| request.requested_role == "reply_received" }
      end

      # One request per tick (and per run) is the intentional concurrency
      # limit. The next tick observes the resulting active worker or planner
      # decision before considering subsequent queued work.
      candidates.first(1)
    end

    def validate_required_artifacts(run:, request:)
      required = Array(request.required_artifacts)
      return true if required.empty?

      artifact_store = ArtifactStore
      available = artifact_store.names(run.target_root, run.run_id)

      missing = required - available
      return true if missing.empty?

      "Required artifacts not found: #{missing.join(', ')}"
    end

    def dispatch_chaperone_request(run:, request:)
      review = ChaperoneReview.find_by(run_id: run.run_id, lineage_key: request.lineage_key, status: %w[queued running])
      unless review
        request.update!(
          status: "dismissed", dismissed_by: "tick_run_job",
          dismissal_note: "No pending chaperone review found for lineage #{request.lineage_key}."
        )
        return
      end

      token = review.reissue_token!
      worker_id = SecureRandom.uuid

      request.update!(
        status: "fulfilled", fulfilled_by: "tick_run_job", fulfilled_at: Time.current,
        fulfillment_note: "Spawned chaperone review #{review.review_id}.", fulfilled_worker_id: worker_id
      )

      begin
        WorkerSpawner.spawn_worker(
          run: run, role: "chaperone", nickname: "chaperone-#{SecureRandom.hex(3)}",
          reason: "Chaperone review: #{review.trigger_reason || review.summary}",
          # No explicit effort: -- agent_personas/chaperone.md declares
          # `effort: high` itself now (WorkerSpawner#persona_declared_effort),
          # a single source of truth instead of hardcoding it here too.
          scope: request.scope, prompt: "Begin.", worker_id: worker_id, model_tier: "strong",
          mcp_override: {
            url: "#{WorkerSpawner.rails_mcp_url}/chaperone", token: token, server_name: "chaperone",
            allowed_tools: Orchestrator::ChaperoneMcpServer::TOOL_NAMES
          }
        )
      rescue => e
        request.update!(
          status: "dismissed", dismissed_by: "tick_run_job",
          dismissal_note: "Claimed chaperone review #{review.review_id} failed to spawn: #{e.message}"
        )
        raise
      end
    end


    def dispatch_reply_received_request(run:, request:)
      review = ReplyReceivedReview.find_by(run_id: run.run_id, review_id: request.lineage_key, status: %w[queued running])
      unless review
        request.update!(
          status: "dismissed", dismissed_by: "tick_run_job",
          dismissal_note: "No pending reply_received review found for #{request.lineage_key}."
        )
        return
      end

      token = review.reissue_token!
      worker_id = SecureRandom.uuid

      request.update!(
        status: "fulfilled", fulfilled_by: "tick_run_job", fulfilled_at: Time.current,
        fulfillment_note: "Spawned reply_received review #{review.review_id}.", fulfilled_worker_id: worker_id
      )

      begin
        WorkerSpawner.spawn_worker(
          run: run, role: "reply_received", nickname: "reply_received-#{SecureRandom.hex(3)}",
          reason: "Classify operator reply to plan-approval question #{review.user_question_id}.",
          scope: request.scope, prompt: "Begin.", worker_id: worker_id, model_tier: "strong",
          mcp_override: {
            url: "#{WorkerSpawner.rails_mcp_url}/reply_received", token: token, server_name: "reply_received",
            allowed_tools: Orchestrator::ReplyReceivedMcpServer::TOOL_NAMES
          }
        )
      rescue => e
        request.update!(
          status: "dismissed", dismissed_by: "tick_run_job",
          dismissal_note: "Claimed reply_received review #{review.review_id} failed to spawn: #{e.message}"
        )
        raise
      end
    end

    def build_worker_nickname(role)
      case role
      when "worker" then "worker"
      when "planner" then "planner"
      when "orchestrator" then "orchestrator"
      else role
      end
    end

    def build_unique_nickname(base_nickname, workers)
      taken = workers.map(&:nickname).to_set
      return base_nickname unless taken.include?(base_nickname)

      suffix = 1
      suffix += 1 while taken.include?("#{base_nickname}-#{suffix}")
      "#{base_nickname}-#{suffix}"
    end

    def build_inherited_artifacts_section(run:, request:)
      inherited = (Array(request.inherited_artifacts) + run.available_launch_artifacts.map { |artifact| artifact["name"] }).compact.uniq
      return nil if inherited.empty?

      artifacts = inherited.filter_map do |name|
        source = run.artifact_source_run(name)
        ArtifactStore.collect(source.target_root, source.run_id, [ name ])[:artifacts].first&.merge(source_run_id: source.run_id)
      end
      existing_artifacts = artifacts.select { |a| a[:exists] }
      return nil if existing_artifacts.empty?

      artifact_lines = existing_artifacts.map do |artifact|
        size_kb = (artifact[:size_bytes].to_f / 1024).round(1)
        origin = run.available_launch_artifacts.find { |entry| (entry["name"] || entry[:name]) == artifact[:name] }
        origin_path = origin && (origin["source_path"] || origin[:source_path]) || "run artifact store"
        "- `#{artifact[:name]}` (#{size_kb} KB, source run `#{artifact[:source_run_id]}`, originating location `#{origin_path}`)"
      end

      artifact_section = "## Inherited Artifacts — Artifact Manifest\n\n"
      artifact_section += "The following read-only artifacts are available. Use the source run id when reading across worktrees:\n\n"
      artifact_section += artifact_lines.join("\n") + "\n\n"
      artifact_section += "Use `read_workflow_artifact` to read these files. All inherited artifacts are read-only."

      artifact_section
    end

    def build_requested_worker_prompt(run_id:, request:, run:)
      artifact_section = build_inherited_artifacts_section(run: run, request: request)

      [
        "Run #{run_id}.",
        "Bus request: #{request.scope}.",
        "Requested by: #{request.asked_by}.",
        (request.requested_role.present? ? "Target role: #{request.requested_role}." : nil),
        request.text,
        (request.context.present? ? "Context: #{request.context}." : nil),
        artifact_section,
        "Write your report via write_workflow_artifact using artifactName=\"#{request.scope}\". Use the shared workflow bus for blockers."
      ].compact.join(" ")
    end

    def execution_mode(request)
      request.execution_mode.presence || request.text.to_s[/\bExecution mode: ([a-z_]+)\./i, 1]&.downcase
    end

    def working_root_for(request:, run:)
      return nil if request.working_root.blank?

      expected = Pathname(run.source_root).expand_path
      actual = Pathname(request.working_root).expand_path
      unless request.requested_role == "git" && request.tags.include?("source-sync") && actual == expected
        raise ArgumentError, "Only a source-sync git handoff may use the workspace source checkout"
      end

      actual.to_s
    end

    def write_scope(request)
      request.write_scope.presence || request.text.to_s[/\bWrite scope: ([a-z_]+)\./i, 1]&.downcase
    end

    def allowed_paths(request, run: nil)
      paths = if request.allowed_paths.present?
        Array(request.allowed_paths)
      else
        raw = request.text.to_s[/\bPlanner-suggested repository paths: (.+?)\./i, 1]
        raw.blank? || raw.casecmp?("none") ? [] : raw.split(",").map(&:strip)
      end

      return paths unless run && execution_mode(request).in?(%w[implementation infrastructure]) && write_scope(request) == "scoped_changes"

      # A planner decides whether a worker is implementing or repairing
      # infrastructure; it must not have
      # to foresee every production and test file the implementation needs.
      # The project-init-discovered source patterns (already including test
      # paths -- see the record_protected_paths prompt) stay protected for
      # all other worker modes and are granted wholesale only here.
      run.workspace.protected_write_patterns
    end
  end
end
