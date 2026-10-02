module McpTools
  # Shared shape for how a run is described to MCP callers. One place, so
  # `list_runs` and `get_run` can never drift into disagreeing about what a
  # run's state is.
  module RunPresenter
    module_function

    # `parents` is parent_run_ids(runs) for a list, so a page of runs costs
    # one lookup rather than one per run.
    def summary(run, parents: nil)
      session = run.latest_session
      parents ||= parent_run_ids([ run ])
      {
        run_id: run.run_id,
        status: run.status,
        task: run.task.to_s.squish.truncate(160),
        driver: run.launcher_variant,
        branch: run.branch_name,
        # What it started from, and merges back into.
        base_branch: run.base_branch,
        # The run this one follows up: the one whose branch it started from.
        parent_run_id: parents[run.id],
        session: session && session_summary(session),
        started_at: run.started_at&.iso8601,
        stopped_at: run.stopped_at&.iso8601
      }.compact
    end

    def detail(run)
      reopen_problem = Orchestrator::SessionReopen.problem(run) if run.session_over?
      summary(run).merge(
        task: run.task,
        worktree: run.target_root,
        worktree_name: run.worktree_name,
        launch_error: run.launch_error,
        launched_by: run.launched_by,
        # Runs started from this one's branch.
        follow_up_run_ids: run.branch_name.present? ? run.workspace.runs.where(base_branch: run.branch_name).order(:created_at).pluck(:run_id) : [],
        # Whether reopen_session would bring its closed session back, and if
        # not, why (nil while it has a session, or is about to).
        reopenable: run.session_over? && reopen_problem.nil?,
        reopen_problem:,
        # The run's own history: one Markdown report per time its session went
        # idle, oldest first, so the last entry is where the run stands now.
        checkpoints: run.checkpoints.map do |checkpoint|
          { at: checkpoint.created_at.iso8601, outcome: checkpoint.outcome, summary: checkpoint.summary }
        end
      ).compact
    end

    # { run.id => the run_id of its parent } for each of `runs` that is a
    # follow-up: its base branch is another run's branch, in its workspace.
    # Worked out rather than stored, since a follow-up is queued with its
    # parent's branch as baseBranch and that is all that ties them.
    def parent_run_ids(runs)
      runs = runs.to_a
      return {} if runs.empty?

      branches = Run.where(workspace_id: runs.map(&:workspace_id).uniq, branch_name: runs.map(&:base_branch).uniq)
        .pluck(:workspace_id, :branch_name, :run_id).to_h { |workspace_id, branch, run_id| [ [ workspace_id, branch ], run_id ] }
      runs.each_with_object({}) do |run, parents|
        parent = branches[[ run.workspace_id, run.base_branch ]]
        parents[run.id] = parent if parent && parent != run.run_id
      end
    end

    def session_summary(session)
      {
        status: session.status,
        # herdr's own view of what the agent is doing right now
        # (idle/working/blocked/done), as opposed to our bookkeeping status.
        agent_status: session.agent_status,
        live: session.live?,
        outcome: session.outcome,
        result: session.result,
        pane: session.herdr_pane_id,
        # The run's own herdr workspace, which is how the herdr plugin tells
        # that an action was invoked from inside this run.
        herdr_workspace: session.herdr_workspace_id,
        last_seen_at: session.last_seen_at&.iso8601
      }.compact
    end
  end
end
