module Orchestrator
  # Ports scripts/workflow-mcp.ts's planning functions: planWorkflowIteration,
  # buildStalledWorkerRecoveryPlan, publishPlannerJobs, buildPendingSpawnKeys.
  # Snake_case throughout -- camelizing for the wire only happens at each
  # MCP tool's McpTools::ToolResponse.structured call.
  module Planner
    module_function

    FRONTEND_KEYWORDS = %w[frontend].freeze
    BACKEND_KEYWORDS = %w[backend].freeze
    INFRASTRUCTURE_KEYWORDS = %w[playwright docker infrastructure toolchain].freeze

    # stall_finding is accepted but intentionally unused -- matches
    # scripts/workflow-mcp.ts's planWorkflowIteration exactly, which also
    # accepts stallFinding without reading it in the routing logic
    # (findingText is built from verifierFinding only). Not a bug to fix
    # here; this is a faithful port.
    def plan_workflow_iteration(task:, verifier_finding: nil, stall_finding: nil)
      finding_text = [ verifier_finding ].compact.join("\n").downcase

      fix_step =
        if FRONTEND_KEYWORDS.any? { |kw| finding_text.include?(kw) }
          { owner: "worker", artifact: "fix-summary.md", success_check: "Adds or updates the preferred frontend test first, then lands the narrowest front/** fix." }
        elsif BACKEND_KEYWORDS.any? { |kw| finding_text.include?(kw) }
          { owner: "worker", artifact: "fix-summary.md", success_check: "Adds or updates a failing request spec first, then lands the narrowest back/** fix." }
        elsif INFRASTRUCTURE_KEYWORDS.any? { |kw| finding_text.include?(kw) }
          { owner: "worker", artifact: "fix-summary.md", success_check: "Adds or updates the preferred infrastructure test first, then lands the narrowest repo-local toolchain or environment fix." }
        else
          { owner: "worker", artifact: "fix-summary.md", success_check: "Adds or updates the narrowest repo-wide regression test first, then lands the smallest general-purpose fix." }
        end

      verify_step = {
        owner: "worker",
        artifact: "verifier-report.md",
        success_check: "Confirms the change addresses the task and cites positive evidence from generated artifacts."
      }

      {
        summary: "#{task}.",
        next_step: fix_step,
        following_steps: [ verify_step ]
      }
    end

    # Used both for a worker that's stalled (still running, idle too long)
    # and for a run that's gone dead (no active workers, no open requests,
    # not marked completed) -- either way the fix is the same: ask a
    # planner to inspect what happened and decide the next bounded handoff.
    def build_stalled_worker_recovery_plan(task:, recovery_finding:, following_steps:)
      summarized_finding = recovery_finding.gsub(/\s+/, " ").strip

      {
        summary: "#{task}. Recover the run via planner. #{summarized_finding}",
        next_step: {
          owner: "planner",
          artifact: "workflow-plan.md",
          success_check: "Inspect this recovery context, determine the next bounded handoff, and publish it with planner_turn: #{summarized_finding}"
        },
        following_steps: following_steps
      }
    end

    def list_planner_declared_artifacts(run_id:)
      SpawnRequest.where(run_id: run_id, asked_by: "planner").distinct.pluck(:scope)
    end

    def build_pending_spawn_keys(run_id:, jobs:)
      jobs.map { |job| [ run_id, job[:step][:owner], job[:step][:artifact] ].to_json }
    end

    # active_worker_ids -- used to tell a stale fulfilled recovery request
    # apart from one that's still in flight. Safe to omit for callers that
    # can never produce a requested_role: 'planner' step (planner_turn's
    # schema restricts next_step.owner to orchestrator|worker).
    def publish_planner_jobs(run_id:, summary:, plan:, active_worker_ids: Set.new)
      step = plan[:next_step]
      return [] if step.nil? || step[:owner] == "orchestrator"

      run = Run.find_by!(run_id: run_id)
      artifact_exists = ->(artifact_name) do
        File.exist?(ArtifactStore.resolve_path(run.target_root, run_id, artifact_name))
      end

      existing_request = SpawnRequest
        .where(run_id: run_id, asked_by: "planner", requested_role: step[:owner], scope: step[:artifact])
        .where.not(status: "dismissed")
        .detect do |request|
          if request.status == "open"
            true
          elsif step[:owner] == "planner"
            request.fulfilled_worker_id.present? && active_worker_ids.include?(request.fulfilled_worker_id)
          else
            artifact_exists.call(step[:artifact]) ||
              (request.fulfilled_worker_id.present? && active_worker_ids.include?(request.fulfilled_worker_id))
          end
        end

      if existing_request
        return [ { step: step, request_id: existing_request.request_id } ]
      end

      request = SpawnRequest.create!(
        run_id: run_id,
        asked_by: "planner",
        scope: step[:artifact],
        text: step[:success_check],
        context: summary,
        requested_role: step[:owner],
        priority: "blocking",
        tags: [ step[:owner], step[:artifact], "planner-job" ]
      )
      [ { step: step, request_id: request.request_id } ]
    end
  end
end
