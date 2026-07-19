module Orchestrator
  # Ports scripts/supervisor-loop.ts's spawnRequestedWorkers -- the
  # claim-before-spawn race-avoidance loop. Must stay sequential (plain
  # Ruby iteration, no parallelism): claiming a spawn request (marking it
  # fulfilled) before actually spawning the worker shrinks the window in
  # which a concurrently-running tick could still see the slot as
  # unclaimed and spawn a duplicate for it. Parallelizing this loop would
  # silently reintroduce the exact double-spawn race this ordering exists
  # to prevent.
  module SpawnRequestedWorkers
    module_function

    def call(run:)
      run_id = run.run_id
      active_workers = Worker.where(run_id: run_id, status: "running").to_a
      current_workers = Worker.where(run_id: run_id).to_a

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
          worker = WorkerSpawner.spawn_worker(
            run: run, role: role, nickname: nickname, reason: reason, scope: request.scope, prompt: prompt,
            worker_id: worker_id, mode: execution_mode(request), write_scope: write_scope(request),
            allowed_paths: allowed_paths(request), model_tier: request.model_tier
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

    def collect_spawn_requests(run_id:, active_workers:)
      active_keys = active_workers.map { |worker| [ worker.role, worker.scope ] }.to_set
      latest_by_key = {}

      SpawnRequest.where(run_id: run_id, status: "open").each do |request|
        next unless request.requested_role.present?

        key = [ request.requested_role, request.scope ]
        next if active_keys.include?(key)

        latest_by_key[key] = request
      end

      latest_by_key.values
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

    def allowed_paths(request)
      return Array(request.allowed_paths) if request.allowed_paths.present?

      raw = request.text.to_s[/\bAllowed repository paths: (.+?)\./i, 1]
      return [] if raw.blank? || raw.casecmp?("none")

      raw.split(",").map(&:strip)
    end
  end
end
