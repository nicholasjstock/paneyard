module Orchestrator
  # A workspace's checkout on a runner, made when it is needed. Every runner,
  # the local one included, is alike: one that has a workspace_checkouts row
  # uses it; one that has none clones the workspace's origin into its
  # projects directory (RegisteredRunner#clone_projects_dir), as
  # <projects dir>/<workspace name>, through the runner's ensure_checkout,
  # which reuses a clone of the same origin already there and refuses
  # anything else, and the path the runner worked out is recorded as its
  # checkout.
  #
  # Called where a runner is about to need the repository, never when
  # queuing (which stays fast): a run's launch (GitWorktree.provision!),
  # moving a run to the runner (RunMove), and opening the lobby (LobbyOpen).
  #
  # The origin is the workspace's origin_url, else read from a checkout it
  # already has on another runner (and then stored). A clone only reads
  # from origin; it never touches anything already at the path.
  module WorkspaceCheckout
    # The runner could not get a checkout: no projects directory, no origin,
    # something else at the path, a clone that failed (credentials, say).
    class Unavailable < Runner::Error; end

    # A workspace name becomes one directory under the projects directory.
    DIRECTORY_NAME = /\A[A-Za-z0-9_][A-Za-z0-9._-]{0,99}\z/

    LOCKS = Hash.new { |locks, key| locks[key] = Mutex.new }
    LOCKS_GUARD = Mutex.new

    module_function

    # The repository's path on `runner` (nil: the local one), cloning it
    # there first when it has no checkout. Raises Unavailable.
    def ensure!(workspace, runner)
      runner ||= RegisteredRunner.local
      existing = recorded(workspace, runner)
      return existing.repository_path if existing

      # One clone per workspace and runner at a time in this process: two
      # runs launching together on a runner without a checkout share it.
      lock(workspace, runner).synchronize do
        existing = recorded(workspace, runner)
        return existing.repository_path if existing

        clone!(workspace, runner)
      end
    end

    # Whether `runner` can be handed the workspace: it has a checkout, or a
    # projects directory to clone one into. For listing (queue_run's runner,
    # get_run's moveTo); ensure! is what finds out whether a clone works.
    def available?(workspace, runner)
      workspace.checkout_for(runner).present? || runner.clone_projects_dir.present?
    end

    # Where ensure! would clone it on `runner`, or nil when it cannot (no
    # projects directory, or a name that is not one directory).
    def planned_path(workspace, runner)
      dir = runner.clone_projects_dir
      return if dir.blank? || !workspace.name.to_s.match?(DIRECTORY_NAME)

      "#{dir.delete_suffix('/')}/#{workspace.name}"
    end

    # The workspace's origin: stored, else read from one of its checkouts
    # (the local one first) and stored for next time. nil when it has none
    # it can read.
    def origin_url(workspace)
      return workspace.origin_url if workspace.origin_url.present?

      workspace.checkouts.includes(:runner).sort_by { |checkout| checkout.runner.local? ? 0 : 1 }.each do |checkout|
        url = Runner.for(checkout.runner).origin_url(path: checkout.repository_path).to_s.strip
        next if url.empty?

        workspace.update_columns(origin_url: url, updated_at: Time.current)
        return url
      rescue Runner::Error
        next
      end
      nil
    end

    def clone!(workspace, runner)
      path = planned_path(workspace, runner)
      unless path
        reason = if runner.clone_projects_dir.blank?
          "it has no projects directory to clone it into (its plugin's PANEYARD_PROJECTS_DIR, sent when it registers)"
        else
          "the workspace's name is not a directory name to clone it as"
        end
        raise Unavailable, "Runner #{runner.name} has no checkout of workspace #{workspace.name.inspect}, and #{reason}."
      end

      origin = origin_url(workspace)
      unless origin
        raise Unavailable, "Runner #{runner.name} has no checkout of workspace #{workspace.name.inspect}, and the workspace " \
          "has no origin to clone it from."
      end

      result = begin
        Runner.for(runner).ensure_checkout(path:, origin_url: origin, default_base_branch: workspace.default_base_branch)
      rescue Runner::Unreachable
        raise
      rescue Runner::Error => error
        raise Unavailable, "Could not check workspace #{workspace.name.inspect} out on runner #{runner.name}: #{error.message}"
      end
      if (problems = result.fetch("problems")).any?
        raise Unavailable, "#{result.fetch('repository_path')} on runner #{runner.name} cannot be used for workspace " \
          "#{workspace.name.inspect}: #{problems.map { |problem| problem.fetch('message') }.join(' ')}"
      end

      record!(workspace, runner, result.fetch("repository_path"), origin: result["origin_url"])
    end

    def record!(workspace, runner, repository_path, origin: nil)
      ::WorkspaceCheckout.create!(workspace:, runner:, repository_path:)
      workspace.checkouts.reset
      workspace.update_columns(origin_url: origin, updated_at: Time.current) if workspace.origin_url.blank? && origin.present?
      repository_path
    rescue ActiveRecord::RecordNotUnique
      workspace.checkouts.reset
      recorded(workspace, runner)&.repository_path || raise
    rescue ActiveRecord::RecordInvalid => error
      raise Unavailable, "Could not record #{repository_path} as workspace #{workspace.name.inspect}'s checkout on runner " \
        "#{runner.name}: #{error.record.errors.full_messages.to_sentence}"
    end

    def recorded(workspace, runner)
      ::WorkspaceCheckout.find_by(workspace:, runner:)
    end

    def lock(workspace, runner)
      LOCKS_GUARD.synchronize { LOCKS[[ workspace.id, runner.id ]] }
    end
  end
end
