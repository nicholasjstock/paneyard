module Orchestrator
  # Registering a remote runner, as the register_runner MCP tool does it: a
  # second machine's runner-only process (bin/runner), which the herdr plugin
  # there starts and registers on every start, so this is idempotent -- the
  # same name again updates its url, its orchestrator url and the checkouts
  # it names, and leaves everything else as it was.
  #
  # Nothing is saved unless the runner answers at url (Runner::Remote#ping).
  # Each checkout is checked on that runner (check_repository, as
  # register_workspace checks a local one) and recorded as the workspace's
  # workspace_checkouts row for it, at the repository path the runner worked
  # out; one that is wrong is reported and skipped, without failing the
  # others.
  module RunnerRegistration
    module_function

    class Invalid < StandardError; end

    # checkouts: [{ "workspace" => name, "path" => repository path there }].
    # Returns { runner:, hostname:, checkouts: [{ workspace, repository_path }],
    # problems: [{ "workspace", "code", "message" }] }, or raises Invalid
    # with nothing saved.
    def register(name:, url:, orchestrator_url:, checkouts: [])
      name = name.to_s.strip
      raise Invalid, "name is required" if name.empty?
      raise Invalid, "#{name.inspect} is the local runner's name; a remote runner needs another" if name == RegisteredRunner::LOCAL_NAME
      raise Invalid, "orchestratorUrl is required: where this runner's sessions reach the orchestrator's /mcp" if orchestrator_url.to_s.strip.empty?

      record = RegisteredRunner.find_or_initialize_by(name:)
      raise Invalid, "#{name.inspect} is the local runner" if record.persisted? && record.local?

      record.assign_attributes(kind: "remote", url: url.to_s.strip.delete_suffix("/"),
        orchestrator_url: orchestrator_url.to_s.strip.delete_suffix("/"))
      raise Invalid, record.errors.full_messages.to_sentence unless record.valid?

      runner = Runner.for(record)
      hostname = begin
        runner.ping.fetch("hostname", nil)
      rescue Runner::Error => error
        raise Invalid, "the runner at #{record.url} did not answer, so nothing was registered: #{error.message}"
      end

      recorded = []
      problems = []
      record.save!
      Array(checkouts).each do |checkout|
        result = record_checkout(record, runner, checkout)
        result.key?(:problem) ? problems << result.fetch(:problem) : recorded << result
      end
      { runner: record, hostname:, checkouts: recorded, problems: }
    end

    def record_checkout(record, runner, checkout)
      checkout = checkout.to_h.stringify_keys
      workspace_name = checkout["workspace"].to_s
      path = checkout["path"].to_s.strip
      workspace = Workspace.find_by(name: workspace_name)
      return problem(workspace_name, "workspace_not_found", "There is no workspace #{workspace_name.inspect}.") unless workspace
      return problem(workspace_name, "path_blank", "No path given for #{workspace_name}.") if path.empty?

      checked = runner.check_repository(path:, default_base_branch: workspace.default_base_branch)
      if (found = checked.fetch("problems")).any?
        return problem(workspace_name, found.first.fetch("code"),
          "#{path} on #{record.name}: #{found.map { |item| item.fetch('message') }.join(' ')}")
      end

      repository_path = checked.fetch("repository_path")
      row = workspace.checkouts.find_or_initialize_by(runner: record)
      row.update!(repository_path:)
      { workspace: workspace.name, repository_path: }
    rescue Runner::Error => error
      problem(workspace_name, "runner_error", "Could not check #{path} on #{record.name}: #{error.message}")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      problem(workspace_name, "checkout_conflict", "#{path} on #{record.name}: #{error.message}")
    end

    def problem(workspace, code, message)
      { problem: { "workspace" => workspace, "code" => code, "message" => message } }
    end
  end
end
