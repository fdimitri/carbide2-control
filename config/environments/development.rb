require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.active_record.query_log_tags_enabled = true

  config.active_job.queue_adapter = :async

  config.action_controller.perform_caching = false
  config.action_mailer = nil

  config.log_level = ENV.fetch("LOG_LEVEL", "debug").to_sym

  config.hosts.clear
end
