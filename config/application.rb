require_relative "boot"

# API-only Rails app. Loads only the framework pieces we need.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module CarbideControl
  class Application < Rails::Application
    config.load_defaults 8.1

    config.api_only = true

    # Eager-load lib/ so CarbideControl::* and operator/ are available without
    # explicit requires. Operator code under operator/ is loaded by bin/operator
    # directly (it doesn't need Rails autoloading) but lives in the autoload
    # path so the Rails side can call shared helpers if needed.
    config.autoload_lib(ignore: %w[assets tasks])
    config.autoload_paths << Rails.root.join("operator")
    config.eager_load_paths << Rails.root.join("operator")

    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # Liberal CORS for dev; tighten in production via env-specific config.
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins ENV.fetch("ALLOWED_ORIGINS", "*").split(",")
        resource "*",
          headers: :any,
          methods: [:get, :post, :patch, :put, :delete, :options, :head],
          expose:  %w[Authorization]
      end
    end
  end
end
