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

# WORKFLOW_HOT_RELOAD=1 (which bin/production sets) turns eager loading off,
# so a constant that only fails to load under eager loading is never seen in
# production until something happens to touch it.
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

check.call("credentials decrypt") do
  key_file = Rails.root.join("config/master.key")
  if ENV["RAILS_MASTER_KEY"].blank? && !key_file.exist?
    next "skipped: no config/master.key in this checkout (it is gitignored; bin/service restart runs this from main, which has one)"
  end

  config = Rails.application.credentials.config
  raise "config/credentials.yml.enc decrypted to nothing" if config.blank?
  raise "no secret_key_base in credentials" if Rails.application.credentials.secret_key_base.blank?

  "#{config.keys.size} top-level keys"
end

exit(failures.empty? ? 0 : 1)
