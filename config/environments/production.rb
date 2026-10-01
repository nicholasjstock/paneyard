require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Deployed production stays eager-loaded. `bin/production` is the local
  # long-running process against the real database, so it opts into reloads
  # to pick up source fixes between requests and recurring jobs without a
  # manual restart.
  local_hot_reload = ENV["PANEYARD_HOT_RELOAD"] == "1"
  config.enable_reloading = local_hot_reload
  config.eager_load = !local_hot_reload

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding protection. There is no auth and Puma binds 127.0.0.1, but a
  # page the operator visits can re-point its own name at 127.0.0.1; only
  # answering loopback names (plus PANEYARD_ALLOWED_HOSTS, and the host of
  # PANEYARD_RAILS_URL) stops it from driving the UI. See SECURITY.md.
  # /up is not excluded: bin/service and bin/sandbox reach it on 127.0.0.1.
  config.hosts = PaneyardAllowedHosts.hosts
end
