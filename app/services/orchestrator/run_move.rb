module Orchestrator
  # The operator moving a run from the machine it is on to another runner's
  # (docs/multi-runner-plan.md, phase 4): its branch, its uncommitted changes
  # and its saved conversation go with it, and it is reopened there.
  #
  #   1. Check: the destination is another registered runner with a checkout
  #      of the workspace, the run has a branch, and nothing is starting or
  #      working in it (a session still working is refused unless forced).
  #      The destination is asked which of the run's base commits it has
  #      (fetching origin there if not, read-only) before anything changes,
  #      so a runner that cannot be reached refuses up front.
  #   2. Close: a live session goes through SessionClose, so the CLI is gone,
  #      nothing writes to the worktree, and its transcripts are saved.
  #   3. Export from the source runner (Runner#export_run): the branch as a
  #      git bundle, the worktree's staged and unstaged diffs and untracked
  #      files, a fingerprint of them, and the transcripts.
  #   4. Import on the destination (Runner#import_run): the branch fetched
  #      from the bundle (a diverging branch there is refused), the worktree
  #      provisioned on it, the uncommitted state applied and checked against
  #      the fingerprint; then the transcripts put where its CLI looks
  #      (Runner#restore_transcripts).
  #   5. Switch runs.runner_id (and the worktree paths) to the destination,
  #      record the move (RunMoveRecord), and reopen through SessionReopen. The new
  #      session resumes the conversation if that CLI can find it there, and
  #      otherwise starts fresh with the task and newest report
  #      (RunPrompt.compose_reopened). Resuming across machines has not been
  #      confirmed live; nothing here relies on it.
  #   6. Release the source worktree through the runner's usual rule
  #      (release_worktree: removed only if clean and saved). It is usually
  #      kept, being dirty or unpushed; the RunMoveRecord row keeps it in the
  #      janitor's view on that runner.
  #
  # Paneyard still never commits or pushes: the bundle carries commits the
  # session made, the uncommitted state lands uncommitted. Nothing is lost if
  # a step fails: until step 5 the run is still the source runner's, with its
  # worktree untouched there, and an import that fails undoes itself on the
  # destination. A session closed in step 2 stays closed, for the operator to
  # reopen where it was or move again.
  module RunMove
    class NotMovable < StandardError; end
    # A step after the session was closed went wrong; the run is still where
    # it was.
    class Failed < StandardError; end

    module_function

    # Returns { from:, to:, closed: (SessionClose's result or nil), worktree:
    # the destination's path, source_worktree:, source_worktree_error:,
    # transferred:, reopened: (SessionReopen's result or nil), reopen_error:,
    # move: the RunMoveRecord }.
    def call(run, to:, force: false)
      destination = destination!(run, to)
      source_record = run.runner
      destination_repository = run.workspace.repository_path_for(destination)
      check!(run, force:)
      source = Runner.for(run)
      target = Runner.for(destination)
      have = target.known_commits(repository_path: destination_repository, commits: [ run.base_sha ].compact).fetch("have")
      unless source.branch_exists?(repository_path: WorktreeJanitor.repository_for(run), branch: run.branch_name)
        raise NotMovable, "Run #{run.run_id}'s branch `#{run.branch_name}` is not in its repository on #{source_record.name}, " \
          "so there is nothing to move."
      end

      closed = SessionClose.call(run) if run.live_session
      run.reload
      transfer(run, source:, target:, source_record:, destination:, destination_repository:, have:, closed:)
    rescue Runner::Error => error
      raise Failed, failure(run, closed, "Could not move run #{run.run_id} to #{to}: #{error.message}") if closed

      raise NotMovable, "Could not move run #{run.run_id} to #{to}: #{error.message}"
    end

    def transfer(run, source:, target:, source_record:, destination:, destination_repository:, have:, closed:)
      source_repository = WorktreeJanitor.repository_for(run)
      source_root = run.target_root if run.managed_worktree? && run.target_root != source_repository
      exported = source.export_run(run_id: run.run_id, repository_path: source_repository, branch: run.branch_name,
        path: source_root, exclude: have)
      imported = target.import_run(
        repository_path: destination_repository, branch: run.branch_name, base_branch: run.base_branch,
        label: run.worktree_name.presence || run.run_id, head: exported.fetch("head"),
        bundle: exported["bundle"], worktree: exported["worktree"], replaceable: replaceable(run, destination)
      )
      # The reopened session opens it again; until then it is a closed run's.
      target.close_workspace(imported.fetch("workspace_id"))
      transcripts = restore_transcripts(run, target, imported, source_root, exported)

      move = record!(run, source_record:, destination:, source_repository:, source_root:, imported:,
        transferred: transferred(exported, imported, transcripts))
      reopened, reopen_error = reopen(run)
      release_source!(move, source, run)
      {
        from: source_record.name, to: destination.name, closed:, worktree: run.target_root,
        source_worktree: move.source_worktree, source_worktree_error: move.source_worktree_error,
        transferred: move.transferred, reopened:, reopen_error:, move:
      }
    end

    # The runners the run could move to, by name: every other runner with a
    # checkout of its workspace, once it has a branch and is not queued or
    # starting. For showing the option (get_run's moveTo); call re-checks,
    # including whether its session is still working.
    def destinations(run)
      return [] if run.branch_name.blank?
      return [] if run.live_session.nil? && run.status.in?(Run::SESSION_ACTIVE_STATUSES)
      return [] if run.live_session&.status == "starting"

      runners = run.workspace.checkouts.includes(:runner).map(&:runner)
      runners |= [ RegisteredRunner.local ]
      runners.reject { |runner| runner.id == run.runner_id }.map(&:name).sort
    end

    # The registered runner `name`, which must not be the run's own and must
    # have a checkout of its workspace.
    def destination!(run, name)
      destination = RegisteredRunner.find_by(name: name.to_s)
      checked_out = run.workspace.checkouts.includes(:runner).map { |checkout| checkout.runner.name }
      checked_out |= [ RegisteredRunner.local.name ]
      unless destination
        raise NotMovable, "There is no runner named #{name.to_s.inspect}. Workspace #{run.workspace.name.inspect} is checked " \
          "out on: #{checked_out.sort.join(', ')} (list_runners)."
      end
      raise NotMovable, "Run #{run.run_id} is already on #{destination.name}." if destination == run.runner

      run.workspace.repository_path_for(destination)
      destination
    rescue Runner::Error
      raise NotMovable, "Runner #{destination.name} has no checkout of workspace #{run.workspace.name.inspect}; it is checked out " \
        "on: #{checked_out.sort.join(', ')}. Register the checkout there (register_runner) first."
    end

    def check!(run, force:)
      raise NotMovable, "Run #{run.run_id} has no branch yet (its session never started), so there is no work to move." if run.branch_name.blank?

      session = run.live_session
      if session.nil? && run.status.in?(Run::SESSION_ACTIVE_STATUSES)
        raise NotMovable, "Run #{run.run_id} is #{run.status}; move it once its session has started and gone idle, or been closed."
      end
      return if session.nil?

      if session.status == "starting"
        raise NotMovable, "Run #{run.run_id}'s session is still starting; move it once it is up."
      end
      return unless session.status == "running" && !force

      raise NotMovable, "Run #{run.run_id}'s session is still working (it has not reported since it was last given work). " \
        "Wait for its report, or force the move, which closes it mid-turn."
    end

    # The worktrees this run left on `destination` when it moved away, still
    # kept there, with the fingerprint each had when its work was carried
    # off: import may reset one that is still exactly that.
    def replaceable(run, destination)
      run.moves.where(from_runner: destination, source_worktree: %w[kept error]).where.not(source_target_root: [ nil, "" ])
        .filter_map do |move|
          fingerprint = move.transferred["fingerprint"]
          { "path" => move.source_target_root, "fingerprint" => fingerprint } if fingerprint.present? && move.transferred["worktree_exported"]
        end
    end

    def restore_transcripts(run, target, imported, source_root, exported)
      return { "saved" => [], "placed" => [], "skipped" => [] } if exported.fetch("transcripts", []).empty?

      target.restore_transcripts(run_id: run.run_id, cwd: imported.fetch("target_root"), source_cwd: source_root,
        transcripts: exported.fetch("transcripts"))
    rescue Runner::Error => error
      # The conversation is the one thing a reopen can do without: it starts
      # fresh with the task and the newest report.
      { "saved" => [], "placed" => [], "skipped" => [ error.message ] }
    end

    def transferred(exported, imported, transcripts)
      worktree = exported["worktree"] || {}
      {
        "head" => exported.fetch("head"),
        "bundle_bytes" => exported["bundle"].to_s.bytesize,
        "prerequisites" => exported.fetch("prerequisites", []),
        "branch_created" => imported.fetch("branch_created"),
        "changed_files" => worktree.fetch("changed", []),
        "untracked_files" => worktree.fetch("files", []),
        "staged" => worktree["staged"].present?,
        # Whether the fingerprint is the source worktree's (a move back may
        # reset it) rather than only the new one's.
        "worktree_exported" => exported["worktree"].present?,
        "fingerprint" => imported.fetch("fingerprint"),
        "transcripts" => exported.fetch("transcripts", []).map { |item| "#{item['driver']}/#{item['path']}" },
        "transcripts_placed" => transcripts.fetch("placed", []),
        "transcripts_skipped" => transcripts.fetch("skipped", [])
      }
    end

    def record!(run, source_record:, destination:, source_repository:, source_root:, imported:, transferred:)
      Run.transaction do
        # Moving back to a runner reuses the worktree the run left there.
        run.moves.where(from_runner: destination, source_target_root: imported.fetch("target_root"), source_worktree: %w[kept error])
          .update_all(source_worktree: "reused", updated_at: Time.current)
        run.update!(runner: destination, target_root: imported.fetch("target_root"), source_root: imported.fetch("repository_path"))
        run.moves.create!(
          from_runner: source_record, to_runner: destination, source_repository_path: source_repository,
          source_target_root: source_root, source_worktree: source_root ? "kept" : "none",
          target_root: imported.fetch("target_root"), transferred:
        )
      end
    end

    def reopen(run)
      [ SessionReopen.call(run), nil ]
    rescue SessionReopen::NotReopenable => error
      [ nil, error.message ]
    end

    # The worktree left behind, by the same rule as any closed run's.
    def release_source!(move, source, run)
      return if move.source_target_root.blank?

      removed = source.release_worktree(repository_path: move.source_repository_path, path: move.source_target_root,
        base_branch: run.base_branch)
      move.update!(source_worktree: removed ? "removed" : "kept", source_worktree_error: nil)
    rescue Runner::Error => error
      move.update!(source_worktree: "error", source_worktree_error: error.message)
    end

    # The janitor's part: each worktree a move left behind on `runner`
    # ([RunMoveRecord]), released if its work is saved. Returns how many it removed.
    def sweep_left_behind(runner, moves)
      source = Runner.for(runner)
      moves.count do |move|
        release_source!(move, source, move.run)
        move.source_worktree == "removed"
      end
    end

    def failure(run, closed, message)
      reopen = closed ? " Its session was closed for the move; reopen it there (reopen_session) or try the move again." : ""
      "#{message}. Run #{run.run_id} is still on #{run.runner.name}, with its worktree as it was.#{reopen}"
    end
  end
end
