module Orchestrator
  # Runs a queued run waits for (queue_run's `after`): it is not dispatched
  # until every one of them has its work merged into the base branch they
  # share, so its worktree -- made at launch, never at queue time -- starts
  # from a base that already has that work.
  #
  # "Merged" is read from git, not from run state, because nothing in Rails
  # records a merge: the session merges when the operator asks it to, or the
  # operator does it by hand, or a PR is merged outside the app and pulled.
  # The one durable, precise signal is the repository itself: the
  # dependency's branch has commits beyond the commit it started from
  # (base_sha), and its tip is an ancestor of the base branch
  # (Runner#branch_merged?). Status alone cannot say it: `completed` only
  # means the operator closed a session that reported done, whether or not
  # the work went anywhere. A squash or rebase merge leaves the branch's
  # commits out of the base, so it is not seen; update_run_dependencies
  # releases a run waiting on one.
  #
  # Dependencies only gate a run's first launch. A run that already has a
  # branch (a reopened one) started from its dependencies' work then.
  module RunDependencies
    # A dependency in one of these, with its work not merged, will not merge
    # on its own: the dependent is blocked rather than waiting, until the
    # operator reopens the dependency or releases the dependent.
    GIVEN_UP_STATUSES = %w[failed stopped].freeze

    class Invalid < ArgumentError; end

    module_function

    # The dependency runs for `run_ids`, checked: each exists in `workspace`,
    # starts from `base_branch`, has not failed or stopped, and none of them
    # waits, directly or not, on `run_id` (the run being given them, nil for
    # one not queued yet). Raises Invalid with every problem found.
    def validate!(run_ids, workspace:, base_branch:, run_id: nil)
      run_ids = Array(run_ids).map { |id| id.to_s.strip }.reject(&:blank?).uniq
      return [] if run_ids.empty?

      found = workspace.runs.where(run_id: run_ids).index_by(&:run_id)
      problems = run_ids.filter_map do |id|
        dependency = found[id]
        if id == run_id
          "#{id} cannot wait for itself"
        elsif dependency.nil?
          elsewhere = Run.where(run_id: id).where.not(workspace_id: workspace.id).first
          elsewhere ? "#{id} is in workspace #{elsewhere.workspace.name.inspect}, not #{workspace.name.inspect}" : "there is no run #{id}"
        elsif dependency.base_branch != base_branch
          "#{id} starts from `#{dependency.base_branch}`, not `#{base_branch}`; a run can only wait for work merged into its own base branch"
        elsif dependency.status.in?(GIVEN_UP_STATUSES)
          "#{id} is #{dependency.status}; reopen it first, or queue without it"
        elsif run_id && waits_on?(dependency, run_id)
          "#{id} already waits for #{run_id}, so waiting for it would be a cycle"
        end
      end
      raise Invalid, "after: #{problems.join('; ')}." if problems.any?

      run_ids.map { |id| found.fetch(id) }
    end

    # Where `run` stands with its dependencies: nil when it has none, or has
    # launched before; else { state: "met" | "waiting" | "blocked", reason:,
    # runs: [{ run_id:, status:, merged: }] }.
    def status(run)
      return nil unless gating?(run)

      dependencies = run.workspace.runs.where(run_id: run.dependency_run_ids).index_by(&:run_id)
      rows = run.dependency_run_ids.map do |id|
        dependency = dependencies[id]
        { run_id: id, status: dependency&.status || "missing", merged: dependency.present? && merged?(dependency, run) }
      end
      unmerged = rows.reject { |row| row[:merged] }
      given_up = unmerged.select { |row| row[:status].in?(GIVEN_UP_STATUSES + [ "missing" ]) }

      state, reason =
        if unmerged.empty?
          [ "met", nil ]
        elsif given_up.any?
          [ "blocked", "Blocked: #{describe(given_up)}, and #{given_up.one? ? 'its' : 'their'} work is not in `#{run.base_branch}`. " \
            "Reopen it, merge its branch by hand, or release this run with update_run_dependencies." ]
        else
          [ "waiting", "Waiting for #{unmerged.map { |row| row[:run_id] }.join(', ')} to be merged into `#{run.base_branch}`." ]
        end
      { state:, reason:, runs: rows }
    end

    # Whether the dispatcher may start `run`.
    def ready?(run)
      !gating?(run) || status(run).fetch(:state) == "met"
    end

    def gating?(run)
      run.dependency_run_ids.present? && run.branch_name.blank?
    end

    def merged?(dependency, run)
      return false if dependency.branch_name.blank? || dependency.base_sha.blank?

      Runner.for(run.workspace).branch_merged?(
        repository_path: run.workspace.repository_path, branch: dependency.branch_name,
        base_branch: run.base_branch, since: dependency.base_sha
      )
    rescue Runner::Error
      false
    end

    def waits_on?(dependency, run_id, seen = Set.new)
      return false unless seen.add?(dependency.run_id)

      ids = Array(dependency.dependency_run_ids)
      return true if ids.include?(run_id)

      dependency.workspace.runs.where(run_id: ids).any? { |next_one| waits_on?(next_one, run_id, seen) }
    end

    def describe(rows)
      rows.map { |row| row[:status] == "missing" ? "#{row[:run_id]} no longer exists" : "#{row[:run_id]} #{row[:status]}" }
        .to_sentence
    end
    private_class_method :merged?, :waits_on?, :describe
  end
end
