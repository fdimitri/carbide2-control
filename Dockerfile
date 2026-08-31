# Two-stage Dockerfile for carbide2-control.
#
# One image, two entrypoints:
#   - bundle exec rails server   (Rails dashboard / API)
#   - bundle exec bin/operator   (Workspace reconciler)
#
# The Helm chart deploys two Deployments using the same image, each with a
# different `command`. Locally, foreman runs both via Procfile.
#
# The dashboard SPA is NOT baked into this image. It lives only in the MinIO
# static tier (built + uploaded by the meta-repo `scripts/build-client --mode
# control`, and by deploy.rb) as the "carbide2-control" family, served at
# /clients/carbide2-control/<sha>/. The Rails SpaController is a loader that
# resolves + serves the pinned dashboard build's index.html at request time.

# --- Rails + operator runtime
FROM ruby:3.4.2-slim

ENV LANG=C.UTF-8 \
    RAILS_LOG_TO_STDOUT=1 \
    BUNDLE_PATH=/usr/local/bundle

# Build provenance — persisted as env for the /api/v1/*/version endpoints to
# report at runtime. Supplied by scripts/build-all.sh as build-args.
ARG META_SHA=unknown
ARG CONTROL_SHA=unknown
ARG BUILD_TIME=unknown
ENV CARBIDE_META_SHA=$META_SHA \
    CARBIDE_CONTROL_SHA=$CONTROL_SHA \
    CARBIDE_BUILD_TIME=$BUILD_TIME

# OS deps. libpq for pg gem; build tools for native extensions; git for any
# git-based gems; tzdata for active_support.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev libyaml-dev tzdata git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4 --retry 3

COPY . .

RUN bundle exec bootsnap precompile --gemfile app/ lib/ operator/ bin/ config/ 2>&1 || true

EXPOSE 3001

# Default to the Rails server. Override `command:` in the operator Deployment.
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3001"]
