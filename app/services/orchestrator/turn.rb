module Orchestrator
  # Ports scripts/orchestrator-turn.ts, scripts/worker-turn.ts,
  # scripts/planner-turn.ts. Snake_case throughout -- camelizing for the
  # wire only happens at each MCP tool's McpTools::ToolResponse.structured
  # call (see Orchestrator::TickState for the DB read/write boundary).
  module Turn
    module_function

    DEFAULT_STALE_AFTER_MS = 120_000
    PLANNER_FOLLOWUP_SCOPE = "workflow-plan.md"

    def run_orchestrator_turn(run_id:, task:, stale_after_ms: nil, now: Time.current, previous_state: nil)
      run = Run.find_or_create_for_bus!(run_id)
      run.publish_phase!(
        phase: "starting",
        owner: "orchestrator",
        summary: "Opening orchestrator phase for: #{task}; coordinating the next worker handoff."
      )

      workers = Worker.where(run_id: run_id, status: "running").to_a
      stalled_workers = detect_stalled_workers(workers: workers, now: now, stale_after_ms: stale_after_ms || DEFAULT_STALE_AFTER_MS)
      stall_finding = stalled_workers.any? ? build_stall_finding(stalled_workers) : nil

      # A run that made real progress (phase advanced past 'starting') but
      # now has nothing active and nothing pending, and was never marked
      # 'completed', has gone dead -- the same class of problem as a
      # stalled worker, just invisible to detect_stalled_workers because
      # there's no running worker left to look at.
      open_spawn_request_count = SpawnRequest.where(run_id: run_id, status: "open").count
      is_dead_end = stall_finding.nil? &&
        workers.empty? &&
        open_spawn_request_count.zero? &&
        previous_state.present? &&
        previous_state[:phase] != "starting" &&
        previous_state[:phase] != "completed"
      dead_end_finding = is_dead_end ? build_dead_end_finding(run_id: run_id, following_steps: previous_state&.dig(:following_steps) || []) : nil
      recovery_finding = stall_finding || dead_end_finding

      # A recovery planner may have already escalated this exact
      # stall/dead-end to a blocking user question. Without this check the
      # orchestrator has no memory of that -- it would just re-detect the
      # same still-idle workers next tick and spawn *another* recovery
      # planner to redundantly re-investigate something already awaiting a
      # human answer.
      has_open_blocking_question = UserQuestion.exists?(run_id: run_id, status: "open", priority: "blocking")

      # A non-stalled, non-dead-end tick is a pure no-op: worker_turn/planner_turn
      # own all real progress, so there is nothing for the orchestrator to
      # decide or publish here.
      plan =
        if recovery_finding.present? && !has_open_blocking_question
          Planner.build_stalled_worker_recovery_plan(
            task: task,
            recovery_finding: recovery_finding,
            following_steps: previous_state&.dig(:following_steps) || []
          )
        end

      jobs =
        if plan
          Planner.publish_planner_jobs(
            run_id: run_id,
            summary: plan[:summary],
            plan: plan,
            active_worker_ids: workers.map(&:worker_id).to_set
          )
        else
          []
        end

      next_phase =
        if has_open_blocking_question
          "blocked_on_user"
        elsif recovery_finding
          "stalled"
        elsif workers.any?
          "waiting_on_workers"
        else
          previous_state&.dig(:phase) || "starting"
        end

      next_state = {
        run_id: run_id,
        phase: next_phase,
        tick_count: (previous_state&.dig(:tick_count) || 0) + 1,
        last_plan_summary: plan&.dig(:summary) || previous_state&.dig(:last_plan_summary),
        pending_spawn_keys: ((previous_state&.dig(:pending_spawn_keys) || []) + Planner.build_pending_spawn_keys(run_id: run_id, jobs: jobs)).uniq,
        following_steps: plan&.dig(:following_steps) || previous_state&.dig(:following_steps) || [],
        last_stall_finding: recovery_finding,
        last_updated_at: now.utc.iso8601(3)
      }

      { plan: plan, jobs: jobs, stalled_workers: stalled_workers, next_state: next_state }
    end

    # task is part of the MCP tool's input schema for API-surface
    # consistency with the other turn tools, but -- matching
    # scripts/worker-turn.ts exactly -- is never actually read here.
    def run_worker_turn(run_id:, role:, nickname:, scope:, result:, now: Time.current, previous_state: nil)
      following_steps = previous_state&.dig(:following_steps) || []
      active_worker_ids = Worker.where(run_id: run_id, status: "running").pluck(:worker_id).to_set

      # A follow-up planner request is a repeatable recovery ask, not a
      # one-time artifact -- an 'open' request is safe to reuse
      # unconditionally, but a 'fulfilled' one only still represents
      # "already being handled" while the planner it spawned is still
      # active.
      existing_request = SpawnRequest
        .where(run_id: run_id, requested_role: "planner", scope: PLANNER_FOLLOWUP_SCOPE)
        .where.not(status: "dismissed")
        .detect { |request| request.status == "open" || (request.fulfilled_worker_id.present? && active_worker_ids.include?(request.fulfilled_worker_id)) }

      planner_request = existing_request || SpawnRequest.create!(
        run_id: run_id,
        asked_by: "worker",
        scope: PLANNER_FOLLOWUP_SCOPE,
        text: "Decide the next nextStep (usually the head of followingSteps, but reconsider it against the reported " \
          "result) and the new followingSteps, then publish them with planner_turn. If blocked on a user decision, " \
          "call append_user_question.",
        context: [
          "Worker #{nickname} (role #{role}) reported this result for run #{run_id}, scope #{scope}: #{result}",
          "Current followingSteps queue (JSON, decided by the previous planner_turn call): #{following_steps.to_json}"
        ].join(" "),
        requested_role: "planner",
        priority: "blocking",
        tags: [ "planner", PLANNER_FOLLOWUP_SCOPE, "worker-turn-followup" ]
      )

      # phase/tick_count/last_plan_summary/last_stall_finding/following_steps
      # are all owned by planner_turn and orchestrator-turn's stall
      # detection -- worker_turn only requests the follow-up planner and
      # reports what it saw, so it carries all of this forward untouched.
      next_state = {
        run_id: run_id,
        phase: previous_state&.dig(:phase) || "starting",
        tick_count: previous_state&.dig(:tick_count) || 0,
        last_stall_finding: previous_state&.dig(:last_stall_finding),
        last_plan_summary: previous_state&.dig(:last_plan_summary),
        pending_spawn_keys: previous_state&.dig(:pending_spawn_keys) || [],
        following_steps: following_steps,
        last_updated_at: now.utc.iso8601(3)
      }

      { planner_request: { request_id: planner_request.request_id }, next_state: next_state }
    end

    def run_planner_turn(run_id:, summary:, next_step:, following_steps:, now: Time.current, previous_state: nil)
      jobs = Planner.publish_planner_jobs(
        run_id: run_id,
        summary: summary,
        plan: { summary: summary, next_step: next_step, following_steps: following_steps }
      )

      next_state = {
        run_id: run_id,
        # next_step: nil is the planner's explicit "genuinely nothing left
        # to do" signal -- mark the run completed so the orchestrator can
        # tell a legitimate finish apart from a run that went idle without
        # ever being told it was done.
        phase: next_step ? "planning" : "completed",
        tick_count: (previous_state&.dig(:tick_count) || 0) + 1,
        last_plan_summary: summary,
        pending_spawn_keys: ((previous_state&.dig(:pending_spawn_keys) || []) + Planner.build_pending_spawn_keys(run_id: run_id, jobs: jobs)).uniq,
        following_steps: following_steps,
        last_stall_finding: previous_state&.dig(:last_stall_finding),
        last_updated_at: now.utc.iso8601(3)
      }

      { jobs: jobs, next_state: next_state }
    end

    def detect_stalled_workers(workers:, now:, stale_after_ms:)
      now_ms = (now.to_f * 1000).to_i

      workers.filter_map do |worker|
        next unless worker.status == "running"

        latest = collect_latest_progress_at(worker)
        next if latest[:timestamp].nil?

        idle_for_ms = now_ms - latest[:timestamp]
        next if idle_for_ms < stale_after_ms

        {
          worker: {
            worker_id: worker.worker_id, run_id: worker.run_id, role: worker.role, nickname: worker.nickname,
            scope: worker.scope, reason: worker.reason
          },
          idle_for_ms: idle_for_ms,
          evidence: [ "worker=#{worker.nickname}", "role=#{worker.role}", "idle_for_ms=#{idle_for_ms}", *latest[:evidence] ]
        }
      end
    end

    def collect_latest_progress_at(worker)
      evidence = []
      latest = nil

      [ [ "log", worker.log_path ], [ "last-message", worker.last_message_path ], [ "prompt", worker.prompt_path ] ].each do |label, path|
        ts = read_mtime_ms(path)
        next if ts.nil?

        evidence << "#{label} mtime=#{Time.at(ts / 1000.0).utc.iso8601(3)}"
        latest = latest.nil? ? ts : [ latest, ts ].max
      end

      { timestamp: latest, evidence: evidence }
    end

    def read_mtime_ms(path)
      return nil if path.blank? || !File.exist?(path)

      (File.mtime(path).to_f * 1000).to_i
    rescue
      nil
    end

    def build_stall_finding(stalls)
      stalls.map do |stall|
        worker = stall[:worker]
        [
          "Stalled worker #{worker[:nickname]} (#{worker[:role]})",
          "run_id=#{worker[:run_id]}",
          "idle_for_ms=#{stall[:idle_for_ms]}",
          "scope=#{worker[:scope]}",
          "reason=#{worker[:reason]}",
          "evidence=#{stall[:evidence].join("; ")}"
        ].join(" | ")
      end.join("\n")
    end

    # A run can go dead without ever looking "stalled": a worker stops
    # (crash, or a clean exit whose worker_turn call never landed) without
    # producing a follow-up spawn request.
    def build_dead_end_finding(run_id:, following_steps:)
      [
        "Run #{run_id} has no active workers and no open spawn requests, but was not marked completed.",
        "following_steps queue at last check: #{following_steps.to_json}",
        "The most recent worker likely stopped without completing its worker_turn handoff (crashed, or the call " \
          "failed) -- inspect its last known report/artifact and decide whether to retry, fix, or escalate to the user."
      ].join(" ")
    end
  end
end
