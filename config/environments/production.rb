require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.active_record.dump_schema_after_migration = false

  config.log_level = ENV.fetch("LOG_LEVEL", "info").to_sym
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)

  config.action_controller.perform_caching = true

  config.active_job.queue_adapter = :async
end
