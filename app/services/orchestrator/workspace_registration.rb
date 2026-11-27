module Orchestrator
  # Registering a workspace, as the register_workspace MCP tool does it:
  # every problem with the
  # proposed repository is found first -- whether it is a git checkout, with a
  # local default branch and an origin, which the runner checks
  # (Runner::Local#check_repository, the same branch rule a queued run is held
  # to), and whether another workspace already has that name or repository --
  # and nothing is saved unless there are none. A broken workspace is caught
  # here rather than by its first run.
  #
  # The checkout is on any runner: the local one unless `runner` names
  # another, which is how a repository that exists only on a remote machine
  # is registered. Only that runner's checkout is recorded; the workspace
  # keeps the repository's origin, which other runners clone when they need
  # it (WorkspaceCheckout).
  module WorkspaceRegistration
    module_function

    # Returns { "repository_path" (the repository's own checkout, worked out
    # from `path`), "default_base_branch" (given, or detected), "origin_url",
    # "name", "problems" => [{ "code", "message" }] }. `workspace` is the
    # record being edited, if any: it does not conflict with itself, and its
    # name is fixed. A blank name means one from the repository's directory.
    # `runner` (a RegisteredRunner, nil: the local one) is where the path is.
    def check(path:, name: nil, default_base_branch: nil, workspace: nil, runner: nil)
      runner ||= RegisteredRunner.local
      result = begin
        Runner.for(runner).check_repository(path:, default_base_branch: default_base_branch.presence)
      rescue Runner::Error => error
        { "repository_path" => path.to_s, "default_base_branch" => default_base_branch, "origin_url" => nil,
          "problems" => [ { "code" => "runner_error", "message" => "Could not check #{path} on #{runner.name}: #{error.message}" } ] }
      end

      name = workspace&.persisted? ? workspace.name : (name.to_s.strip.presence || default_name(result.fetch("repository_path"), workspace))
      result.merge(
        "name" => name,
        "runner" => runner.name,
        "problems" => conflicts(name:, repository_path: result.fetch("repository_path"), workspace:, runner:) + result.fetch("problems")
      )
    end

    # Creates the workspace when check finds nothing wrong. Returns
    # [workspace or nil, check result].
    def register(path:, name: nil, default_base_branch: nil, runner: nil)
      runner ||= RegisteredRunner.local
      result = check(path:, name:, default_base_branch:, runner:)
      return [ nil, result ] if result.fetch("problems").any?

      workspace = Workspace.new(
        name: result.fetch("name"), default_base_branch: result.fetch("default_base_branch"), origin_url: result["origin_url"]
      )
      workspace.record_checkout(runner, result.fetch("repository_path"))
      workspace.save!
      [ workspace, result ]
    end

    # The repository directory's name, made unique.
    def default_name(repository_path, workspace)
      base = File.basename(repository_path.to_s).gsub(/[^A-Za-z0-9._-]+/, "-").presence || "workspace"
      taken = Workspace.where.not(id: workspace&.id).pluck(:name)
      ([ base ] + (2..).first(100).map { |n| "#{base}-#{n}" }).find { |candidate| !taken.include?(candidate) }
    end

    # Another workspace has the name, or already has its checkout on
    # `runner` (nil: the local one) at that path.
    def conflicts(name:, repository_path:, workspace:, runner: nil)
      runner ||= RegisteredRunner.local
      others = Workspace.all
      others = others.where.not(id: workspace.id) if workspace&.persisted?
      problems = []

      unless workspace&.persisted?
        if name.blank?
          problems << { "code" => "name_blank", "message" => "name is required." }
        elsif others.exists?(name:)
          problems << { "code" => "name_taken", "message" => "A workspace named #{name.inspect} already exists; choose another name." }
        end
      end

      if repository_path.to_s.start_with?("/")
        taken = ::WorkspaceCheckout.where(runner:, workspace: others).includes(:workspace)
          .find { |checkout| same_path?(checkout.repository_path, repository_path) }
      end
      if taken
        on = runner.local? ? "" : " on #{runner.name}"
        problems << { "code" => "repository_taken",
                      "message" => "Workspace #{taken.workspace.name.inspect} is already registered for #{taken.repository_path}#{on}." }
      end
      problems
    end

    def same_path?(one, other)
      Pathname(one.to_s).expand_path.cleanpath == Pathname(other.to_s).expand_path.cleanpath
    end
  end
end
