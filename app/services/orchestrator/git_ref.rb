module Orchestrator
  # What may be used as a branch name here: a run's base branch, a
  # workspace's default one. Plain data, so the orchestrator's models and the
  # runner's git checks agree without either reaching into the other.
  module GitRef
    # No leading dash (it ends up in argv), and nothing git itself forbids in a
    # branch name.
    BRANCH_FORMAT = %r{\A(?!-)(?!.*\.\.)(?!.*//)(?!.*@\{)[^\s~^:?*\[\\]+(?<![./])(?<!\.lock)\z}

    module_function

    def branch?(name)
      name.is_a?(String) && name.match?(BRANCH_FORMAT)
    end
  end
end
