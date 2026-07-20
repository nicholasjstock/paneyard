module Orchestrator
  # Ports scripts/workflow-mcp.ts's planning functions: planWorkflowIteration,
  # buildStalledWorkerRecoveryPlan, publishPlannerJobs, buildPendingSpawnKeys.
  # Snake_case throughout -- camelizing for the wire only happens at each
  # MCP tool's McpTools::ToolResponse.structured call.
  module Planner
    module_function

    # stall_finding is accepted but intentionally unused -- matches
    # scripts/workflow-mcp.ts's planWorkflowIteration exactly, which also
    # accepts stallFinding without reading it in the routing logic
    # (findingText is built from verifierFinding only). Not a bug to fix
    # here; this is a faithful port.
    def plan_workflow_iteration(task:, verifier_finding: nil, stall_finding: nil)
      fix_step = {
        owner: "worker", artifact: "fix-summary.md",
        success_check: "Reproduce the reported failure and identify the confirmed boundary with direct evidence; keep repository files read-only."
      }

      verify_step = {
        owner: "worker",
        artifact: "verifier-report.md",
        success_check: "Confirms the change addresses the task and cites positive evidence from generated artifacts.",
        mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
      }

      fix_step.merge!(
        mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [],
        evidence_refs: [ verifier_finding ].compact
      )

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
          success_check: "Inspect the recovery evidence, identify why the handoff did not complete, and publish the next bounded step with planner_turn.",
          mode: "diagnosis", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [ summarized_finding ]
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
    # apart from one that's still in flight.
    def publish_planner_jobs(run_id:, summary:, plan:, active_worker_ids: Set.new)
      step = plan[:next_step]
      return [] if step.nil?

      # The normal planner-submitted path always sets this already (the
      # model declared it); the Rails-hardcoded recovery builders above
      # (plan_workflow_iteration, build_stalled_worker_recovery_plan) never
      # do, so default to "addresses everything currently outstanding"
      # rather than failing acceptance-criteria validation on a step Rails
      # generated itself.
      step[:addresses_criteria] ||= AcceptanceCriteria.current_keys(run_id: run_id)

      StepPolicy.validate!(run_id:, step:)

      existing_request = SpawnRequest
        .where(run_id: run_id, asked_by: "planner", requested_role: step[:owner], scope: step[:artifact])
        .where.not(status: "dismissed")
        .detect do |request|
          if request.status == "open"
            true
          else
            request.fulfilled_worker_id.present? && active_worker_ids.include?(request.fulfilled_worker_id)
          end
        end

      if existing_request
        return [ { step: step, request_id: existing_request.request_id } ]
      end

      request = SpawnRequest.create!(
        run_id: run_id,
        asked_by: "planner",
        scope: step[:artifact],
        text: StepPolicy.worker_instructions(step),
        context: summary,
        requested_role: step[:owner],
        execution_mode: step[:mode],
        write_scope: step[:write_scope],
        allowed_paths: Array(step[:allowed_paths]),
        evidence_refs: Array(step[:evidence_refs]),
        lineage_key: step[:lineage_key].presence || step[:artifact],
        priority: "blocking",
        tags: [ step[:owner], step[:artifact], "planner-job" ]
      )
      [ { step: step, request_id: request.request_id } ]
    end
  end
end
