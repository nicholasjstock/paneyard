module Orchestrator
  # Ports scripts/worker-turn.ts and scripts/planner-turn.ts. Snake_case throughout -- camelizing for the
  # wire only happens at each MCP tool's McpTools::ToolResponse.structured
  # call (see Orchestrator::TickState for the DB read/write boundary).
  module Turn
    module_function

    PLANNER_FOLLOWUP_SCOPE = "workflow-plan.md"

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
      completion_blockers = Orchestrator::RunContext.completion_blockers(run_id: run_id)
      if next_step.nil? && completion_blockers.any?
        raise ArgumentError, "Cannot complete run while acceptance criteria remain pending: #{completion_blockers.join(', ')}"
      end

      jobs = Planner.publish_planner_jobs(
        run_id: run_id,
        summary: summary,
        plan: { summary: summary, next_step: next_step, following_steps: following_steps }
      )
      # The planner that is submitting this decision remains registered as
      # running until its CLI process exits. It is not work that should keep
      # the run alive after a nil next_step, otherwise every completed planner
      # turn becomes waiting_on_workers and the stall recovery loop restarts.
      active_executor_exists = Worker.where(run_id: run_id, status: "running").where.not(role: "planner").exists?
      has_open_blocking_question = UserQuestion.exists?(run_id: run_id, status: "open", priority: "blocking")
      completion_phase =
        if has_open_blocking_question
          "blocked_on_user"
        elsif next_step
          "planning"
        elsif active_executor_exists
          "waiting_on_workers"
        else
          "completed"
        end

      next_state = {
        run_id: run_id,
        # next_step: nil only means "completed" when nothing is still in
        # flight. A recovery planner can legitimately publish no new
        # immediate handoff because an existing worker should continue
        # uninterrupted; in that case the run must stay
        # waiting_on_workers rather than flipping completed.
        phase: completion_phase,
        tick_count: (previous_state&.dig(:tick_count) || 0) + 1,
        last_plan_summary: summary,
        pending_spawn_keys: ((previous_state&.dig(:pending_spawn_keys) || []) + Planner.build_pending_spawn_keys(run_id: run_id, jobs: jobs)).uniq,
        following_steps: following_steps,
        last_stall_finding: previous_state&.dig(:last_stall_finding),
        last_updated_at: now.utc.iso8601(3)
      }

      { jobs: jobs, next_state: next_state }
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
    public :build_dead_end_finding
  end
end
