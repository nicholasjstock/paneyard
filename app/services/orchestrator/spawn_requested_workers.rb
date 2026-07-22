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

        nickname = build_unique_nickname(build_worker_nickname(role), current_workers + spawned_workers)
        reason = "Bus request from #{request.asked_by} for #{request.scope}."
        prompt = build_requested_worker_prompt(run_id: run_id, request: request)
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
          worker = WorkerSpawner.spawn_worker(
            run: run, role: role, nickname: nickname, reason: reason, scope: request.scope, prompt: prompt,
            worker_id: worker_id, mode: execution_mode(request), write_scope: write_scope(request),
            allowed_paths: effective_allowed_paths, model_tier: request.model_tier
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

      # One request per tick (and per run) is the intentional concurrency
      # limit. The next tick observes the resulting active worker or planner
      # decision before considering subsequent queued work.
      candidates.first(1)
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
          scope: request.scope, prompt: chaperone_prompt(review), worker_id: worker_id, model_tier: "strong",
          mcp_override: {
            url: "#{WorkerSpawner.rails_mcp_url}/chaperone", token: token,
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

    def chaperone_prompt(review)
      if review.subject_type == "planner"
        "You must begin by calling get_chaperone_state. Review the bounded small-model planner attempt and its failure using only the chaperone MCP tools. " \
          "Choose continue_small when the failure can be corrected by a bounded retry with clearer context, including invalid verification evidence, an unverified service or endpoint, or an unnecessary protected-path proposal. " \
          "Choose promote only for a genuine reasoning-capability gap. Choose stop only when no safe in-scope retry exists and a real external decision is unavoidable; never stop merely because the planner proposed unauthorized work when an in-scope alternative remains. " \
          "When evidence identifies a concrete, fixable condition that would change the next attempt, provide revisedInstruction with the replacement instruction; otherwise leave it null. " \
          "Your summary must state the concrete next action. You must finish by calling submit_chaperone_decision exactly once; a text-only answer is a failure."
      else
        "You must begin by calling get_chaperone_state. Review repeated diagnosis attempts using only the chaperone MCP tools. Determine semantic similarity and progress. " \
          "Choose continue_small or promote only when the same execution envelope can succeed with a corrected instruction or stronger worker. " \
          "When the evidence shows the envelope itself cannot solve the blocker (for example a source-protected recording must first change an exact configuration or source file), choose stop WITH plannerTier=small or strong, a blockerKey, and one or more contextRequests. This means REPLACE the failed envelope: Rails starts one selected-tier planner that may create a new mode, owner, writable-path scope, artifact, and follow-up sequence. It does not ask the user. Choose small when the evidence makes the replacement obvious and strong only for real repair-scope uncertainty. blockerKey is a short lowercase-hyphenated slug naming the specific blocking condition (e.g. 'stale-recorder-assertion', 'docker-unavailable'). get_chaperone_state's priorBlockers lists every blockerKey already used for this lineage -- check it before choosing one: if the current blocker is the same underlying condition as an entry there, reuse that exact key even if you would phrase it differently, so Rails recognizes the repeat and asks the user instead of replanning the same fix again; pick a new key only when the evidence shows a genuinely different blocker, even within the same lineage, including a small-tier replan that failed only because it was scoped too narrowly. Context requests may name only artifact, run_context, or worker_log windows; use the smallest useful windows. " \
          "Choose stop WITHOUT plannerTier only when no safe bounded repair plan exists and a real external decision is unavoidable. " \
          "You must finish by calling submit_chaperone_decision exactly once; a text-only answer is a failure."
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

    def build_requested_worker_prompt(run_id:, request:)
      [
        "Run #{run_id}.",
        "Bus request: #{request.scope}.",
        "Requested by: #{request.asked_by}.",
        (request.requested_role.present? ? "Target role: #{request.requested_role}." : nil),
        request.text,
        (request.context.present? ? "Context: #{request.context}." : nil),
        "Write your report via write_workflow_artifact using artifactName=\"#{request.scope}\". Use the shared workflow bus for blockers."
      ].compact.join(" ")
    end

    def execution_mode(request)
      request.execution_mode.presence || request.text.to_s[/\bExecution mode: ([a-z_]+)\./i, 1]&.downcase
    end

    def write_scope(request)
      request.write_scope.presence || request.text.to_s[/\bWrite scope: ([a-z_]+)\./i, 1]&.downcase
    end

    def allowed_paths(request, run: nil)
      paths = if request.allowed_paths.present?
        Array(request.allowed_paths)
      else
        raw = request.text.to_s[/\bAllowed repository paths: (.+?)\./i, 1]
        raw.blank? || raw.casecmp?("none") ? [] : raw.split(",").map(&:strip)
      end

      return paths unless run && execution_mode(request) == "implementation" && write_scope(request) == "scoped_changes"

      # A planner decides whether a worker is implementing; it must not have
      # to foresee every production and test file the implementation needs.
      # The project-init-discovered source patterns stay protected for all
      # other worker modes and are granted wholesale only here.
      (run.workspace.protected_write_patterns + run.workspace.test_write_roots.map { |root| "#{root}/**" }).uniq
    end
  end
end
