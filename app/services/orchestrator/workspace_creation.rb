module Orchestrator
  # Getting a project ready and registered as a workspace in one call, as the
  # create_workspace MCP tool does it, from whatever already exists: nothing
  # yet, a local directory or repository without a GitHub one, or a GitHub
  # repository not cloned here. The runner plans and carries out the missing
  # steps (Runner::Local#check_project, #create_project), and then it is
  # registered exactly as register_workspace registers a checkout
  # (WorkspaceRegistration.register), on the default branch the runner found.
  #
  # Where it goes is `path`, else the projects_dir setting joined with the
  # name; there is no guessed default, so with neither the call is refused
  # with how to set the setting (update_settings). The name defaults to the
  # path's directory name; it is also the GitHub repository's and the
  # workspace's. The owner is `owner`, else the default_github_owner setting,
  # else the runner's gh user.
  #
  # Every problem is found first -- the workspace name and repository are
  # free, and what the runner checks -- and nothing is done unless there are
  # none.
  module WorkspaceCreation
    module_function

    # Returns [path or nil, name, problems].
    def resolve(name:, path:)
      name = name.to_s.strip.presence
      path = path.to_s.strip.presence
      if path
        [ path, name || File.basename(path.chomp("/")), [] ]
      elsif name.nil?
        [ nil, nil, [ problem("name_blank", "name is required (or path, whose directory name it then is).") ] ]
      elsif (dir = Setting["projects_dir"])
        [ File.join(dir, name), name, [] ]
      else
        [ nil, name, [ problem("projects_dir_unset", "No projects directory is set, so there is nowhere to put #{name}. Ask " \
          "the operator where projects go and save it with update_settings projectsDir#{suggestion}, or pass path.") ] ]
      end
    end

    # Returns the runner's plan (Runner::Local#check_project) with "name" and
    # every problem, the workspace's own included.
    def check(name: nil, owner: nil, visibility: nil, path: nil)
      path, name, problems = resolve(name:, path:)
      return blank_plan(path, name).merge("problems" => problems) if problems.any?

      plan = runner_call do |runner|
        runner.check_project(path:, name:, owner: owner.presence || Setting["default_github_owner"], visibility:)
      end
      plan.merge("name" => name, "problems" => conflicts(name, plan) + plan.fetch("problems"))
    end

    # Returns [workspace or nil, result]: check's plan, plus what the runner
    # reports doing ("created", "done", "origin_url", "github_url",
    # "remaining", and "message" when something went wrong), plus
    # "registration_problems" when the project is ready but could not be
    # registered.
    def create(name: nil, owner: nil, visibility: nil, path: nil, description: nil)
      checked = check(name:, owner:, visibility:, path:)
      return [ nil, checked ] if checked.fetch("problems").any?

      made = runner_call do |runner|
        runner.create_project(path: checked.fetch("repository_path"), name: checked.fetch("name"),
                              owner: checked["owner"], visibility: checked["visibility"], description:)
      end
      result = checked.merge(made)
      return [ nil, result ] unless made["created"]

      workspace, registration = WorkspaceRegistration.register(
        path: made.fetch("repository_path"), name: checked.fetch("name"), default_base_branch: made["default_base_branch"]
      )
      return [ workspace, result.merge("origin_url" => registration.fetch("origin_url") || made["origin_url"]) ] if workspace

      [ nil, result.merge("registration_problems" => registration.fetch("problems")) ]
    end

    # Where most existing workspaces' checkouts are, offered when no
    # projects directory is set; never used without being saved.
    def suggestion
      common = Workspace.pluck(:repository_path).map { |path| File.dirname(path.to_s) }.tally.max_by { |_dir, count| count }&.first
      common ? " (most workspaces are in #{common})" : ""
    end

    def conflicts(name, plan)
      WorkspaceRegistration.conflicts(name:, repository_path: plan["repository_path"], workspace: nil)
    end

    def blank_plan(path, name)
      { "repository_path" => path, "name" => name, "owner" => nil, "github_repository" => nil, "visibility" => nil,
        "local" => nil, "default_base_branch" => nil, "steps" => [], "notes" => [] }
    end

    def problem(code, message)
      { "code" => code, "message" => message }
    end

    def runner_call
      yield Runner.for(nil)
    rescue Runner::Error => error
      { "created" => false, "steps" => [], "notes" => [],
        "problems" => [ problem("runner_error", "The runner could not do it: #{error.message}") ] }
    end
  end
end
