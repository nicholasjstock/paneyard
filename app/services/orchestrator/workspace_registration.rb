module Orchestrator
  # Registering a workspace, as the register_workspace MCP tool and the web
  # UI's Add workspace / edit forms both do it: every problem with the
  # proposed name and root is found first -- the layout on disk, which the
  # runner checks (Runner::Local#check_workspace_root, the same rules a launch
  # enforces), and whether another workspace already has that name or root --
  # and nothing is saved unless there are none. A broken workspace is caught
  # here rather than by its first run.
  module WorkspaceRegistration
    module_function

    # Returns { "root_path" (expanded), "source_root", "origin_url",
    # "problems" => [{ "code", "message" }] }. `workspace` is the record being
    # edited, if any: it does not conflict with itself, and its name is fixed.
    def check(name:, root_path:, workspace: nil)
      result = begin
        Runner.for(workspace).check_workspace_root(root_path:)
      rescue Runner::Error => error
        { "root_path" => root_path.to_s, "source_root" => nil, "origin_url" => nil,
          "problems" => [ { "code" => "runner_error", "message" => "Could not check #{root_path}: #{error.message}" } ] }
      end

      result.merge("problems" => conflicts(name:, root_path: result.fetch("root_path"), workspace:) + result.fetch("problems"))
    end

    # Creates the workspace when check finds nothing wrong. Returns
    # [workspace or nil, check result].
    def register(name:, root_path:)
      result = check(name:, root_path:)
      return [ nil, result ] if result.fetch("problems").any?

      [ Workspace.create!(name:, root_path: result.fetch("root_path")), result ]
    end

    def conflicts(name:, root_path:, workspace:)
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

      taken = others.find { |other| same_root?(other.root_path, root_path) } if root_path.to_s.start_with?("/")
      if taken
        problems << { "code" => "root_path_taken",
                      "message" => "Workspace #{taken.name.inspect} is already registered at #{taken.root_path}." }
      end
      problems
    end

    # Stored roots may predate expansion (the form used to save `~/...` as
    # typed), so compare them expanded.
    def same_root?(one, other)
      Pathname(one.to_s).expand_path.cleanpath == Pathname(other.to_s).expand_path.cleanpath
    end
  end
end
