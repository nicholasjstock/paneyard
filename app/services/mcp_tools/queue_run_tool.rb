module McpTools
  class QueueRunTool < MCP::Tool
    tool_name "queue_run"
    # Shared by /mcp/run and /mcp/admin, so the text must not assume which
    # kind of caller is reading it.
    description "Queue a separate job. It gets its own worktree, `paneyard/<name>` branch and agent session, " \
      "starts when a concurrency slot frees, and shares none of your context -- write the task as a complete " \
      "brief: goal, constraints, relevant files, and how to tell it worked. Its branch starts from baseBranch (any " \
      "local branch of the workspace's repository, checked out or not; default: the workspace's defaultBaseBranch) " \
      "and the job merges back into that branch when asked to merge. From outside a run, pass the branch you have " \
      "checked out unless the operator names another. From inside a run, use it only for follow-up " \
      "work the operator asked for, never to hand off your own task. From inside a run, workspace defaults to your " \
      "own. From outside one it is required: call list_workspaces and pass the workspace whose repositoryPath is " \
      "the repository you mean, or, if none is, register it with register_workspace first. When this job must build " \
      "on other jobs' work, pass their runIds as after: it stays queued, holding no slot, until each of them has " \
      "its commits merged into the shared baseBranch, and only then gets its worktree, from the base including " \
      "that work. If one of them fails or is stopped first, it waits as blocked (get_run says why) instead of " \
      "launching. Use after for a genuine order dependency, not to serialise jobs that merely touch the same files. " \
      "Pass runner (a machine, from list_runners where offered) only when the operator names one; by default the job " \
      "runs on your own machine from inside a run, else on a runner with a checkout of the workspace (the local one " \
      "first). A runner without one clones the repository into its projects directory when the job starts."
    input_schema(
      properties: {
        task: { type: "string" },
        workspace: { type: "string", description: "Workspace name to queue the run in. Required from outside a run." },
        baseBranch: { type: "string", description: "Local branch to start from and merge back into (default: the workspace's defaultBaseBranch)." },
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS, description: "Which agent runs it (default claude)." },
        model: { type: "string", description: "Model id for that agent's CLI (default: the driver's default model; list_models, where offered, lists them)." },
        after: {
          type: "array", items: { type: "string" },
          description: "runIds of jobs in the same workspace and baseBranch, not failed or stopped, whose work must be merged into baseBranch before this one starts."
        },
        runner: { type: "string", description: "Name of the runner (machine) to run it on; only when the operator names one." }
      },
      required: %w[task]
    )

    def self.call(task:, server_context:, workspace: nil, baseBranch: nil, driver: nil, model: nil, after: nil, runner: nil)
      raise ArgumentError, "task is required" if task.blank?

      target = WorkspaceResolution.resolve!(server_context:, workspace:, explicit: true)
      machine = Orchestrator::RunRunner.choose!(target, runner, caller_run: WorkspaceResolution.caller_run(server_context))
      base_branch = Orchestrator::RunBaseBranch.for(target, baseBranch)
      problem = Orchestrator::RunBaseBranch.problem(target, base_branch, runner: machine)
      return ToolResponse.error(problem, code: "base_branch_invalid") if problem

      dependencies = Orchestrator::RunDependencies.validate!(after, workspace: target, base_branch:)

      run = target.runs.new(
        runner: machine,
        run_id: "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}",
        task:, base_branch:, launcher_variant: driver.presence || "claude", model: model.to_s.strip.presence,
        target_root: planned_root(target, machine), status: "queued", launched_by: "mcp", dependency_run_ids: dependencies.map(&:run_id)
      )
      run.worktree_name = Orchestrator::GitWorktree.name_for(run)
      run.save!
      RunDispatchJob.perform_later

      response = {
        run_id: run.run_id,
        workspace: target.name,
        runner: machine.name,
        base_branch: run.base_branch,
        driver: run.launcher_variant,
        model: run.model,
        status: run.status,
        after: run.dependency_run_ids.presence,
        dependencies: Orchestrator::RunDependencies.status(run),
        # Older queued runs the dispatcher would start first, in any workspace;
        # not ones waiting or blocked on their own `after`.
        queued_behind: Orchestrator::RunQueue.ahead_count(run),
        capacity: { limit: Orchestrator::RunConcurrency.limit, in_flight: Orchestrator::RunConcurrency.in_flight }
      }
      # Only for a runner with a cap of its own.
      if machine.max_concurrent_runs
        response[:runner_capacity] = { limit: machine.max_concurrent_runs, in_flight: Orchestrator::RunConcurrency.in_flight_on(machine) }
      end
      # The runner has no checkout yet: it clones one when the run launches.
      response[:clones_at_launch] = true unless target.checkout_for(machine)
      ToolResponse.structured(response)
    rescue Orchestrator::RunDependencies::Invalid => error
      ToolResponse.error(error.message, code: "dependency_invalid")
    rescue Orchestrator::RunRunner::Invalid => error
      ToolResponse.error(error.message, code: "runner_invalid")
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end

    # The run's root until its worktree is made: the runner's checkout, or,
    # on a runner that clones one at launch, where that clone will go.
    def self.planned_root(workspace, runner)
      workspace.checkout_path(runner) || Orchestrator::WorkspaceCheckout.planned_path(workspace, runner) ||
        raise(ArgumentError, "runner #{runner.name.inspect} cannot check workspace #{workspace.name.inspect} out")
    end
  end
end
