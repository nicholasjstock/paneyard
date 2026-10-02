# Run by bin/preflight as `bin/rails runner script/preflight_checks.rb`, in the
# production environment against a scratch database that has already been
# prepared (recurring-task validation reads the queue schema). Checks what the
# long-running instance only reads once, at boot, so that a mistake in it
# shows up here instead of after `bin/service restart`.
failures = []
check = lambda do |name, &block|
  detail = block.call
  puts "  ok   #{name}#{" -- #{detail}" if detail.is_a?(String)}"
rescue StandardError, ScriptError => error
  failures << name
  puts "  FAIL #{name}: #{error.class}: #{error.message}"
end

# Production eager loads on boot, so a constant that cannot load stops the
# restart. Name it here, before the running instance is touched.
check.call("eager-load every constant") do
  Rails.application.eager_load!
  "#{ApplicationRecord.descendants.size} models, #{ApplicationJob.descendants.size} jobs"
end

check.call("routes draw, with both MCP endpoints mounted") do
  paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
  missing = %w[/mcp/run /mcp/admin /up].reject { |path| paths.any? { |spec| spec.start_with?(path) } }
  raise "missing #{missing.join(', ')}" if missing.any?

  "#{paths.size} routes"
end

check.call("config/queue.yml and config/recurring.yml (#{Rails.env})") do
  configuration = SolidQueue::Configuration.new(skip_recurring: false)
  raise configuration.errors.full_messages.join("; ") unless configuration.valid?

  processes = configuration.configured_processes.map(&:kind).tally.map { |kind, count| "#{count} #{kind}" }
  tasks = configuration.send(:recurring_tasks)
  # A renamed or mis-indented environment key silently schedules nothing,
  # which Solid Queue considers valid. These two are what free concurrency
  # slots; without them the queue wedges.
  scheduled = tasks.map(&:class_name)
  missing = %w[RunDispatchJob RunSessionReconcileJob] - scheduled
  raise "recurring schedule for #{Rails.env} is missing #{missing.join(', ')}" if missing.any?

  "#{processes.join(', ')}; recurring: #{tasks.map(&:key).join(', ')}"
end

exit(failures.empty? ? 0 : 1)
