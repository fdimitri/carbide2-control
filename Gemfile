source "https://rubygems.org"

# Stay in lockstep with carbide2-server.
gem "rails", "~> 8.1.3"
gem "pg",    "~> 1.5"
gem "puma",  ">= 5.0"
gem "bcrypt", "~> 3.1.7"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

# CORS for the dashboard SPA hitting the API cross-origin in dev.
gem "rack-cors"

# Auth — same stack as server.
gem "devise"
gem "jwt"
gem "dotenv-rails", groups: [:development, :test]

# Kubernetes client for the operator. Used both by `bin/operator` (reconcile
# loop) and indirectly by the Rails app (to create Workspace CRs — though
# Rails only ever writes ONE CRD type, never any built-in resource).
gem "kubeclient", "~> 4.11"

# Foreman to run rails + operator side-by-side in dev (separate processes
# inside the same container in prod, deployed as two separate Deployments).
gem "foreman"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end
