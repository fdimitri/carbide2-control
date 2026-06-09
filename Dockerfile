# Two-stage Dockerfile for carbide2-control.
#
# One image, two entrypoints:
#   - bundle exec rails server   (Rails dashboard / API)
#   - bundle exec bin/operator   (Workspace reconciler)
#
# The Helm chart deploys two Deployments using the same image, each with a
# different `command`. Locally, foreman runs both via Procfile.

# --- Stage 1: build the dashboard SPA from the carbide2-client source.
#
# carbide2-control does NOT track a client commit hash (no submodule). The
# meta-repo `carbide2` (which has all three components as submodules) is
# the single source of truth for client versions and is responsible for
# invoking docker build with the right context. Example:
#
#   docker build -t carbide2-control:dev \
#       --build-context client=../carbide2-client \
#       ./carbide2-control
#
# Requires BuildKit (`docker buildx` or DOCKER_BUILDKIT=1).
FROM node:22-alpine AS dashboard-build
ARG META_SHA=unknown
ARG CLIENT_SHA=unknown
ARG CONTROL_SHA=unknown
ARG BUILD_TIME=unknown

WORKDIR /client
COPY --from=client package.json package-lock.json* ./
RUN npm ci --no-audit --progress=false

COPY --from=client . ./
# VITE_CARBIDE_MODE=control bakes the mode into the bundle so getApiUrl()
# uses /api and DashboardPage routes "open project" to /w/<id>/.
ENV VITE_CARBIDE_MODE=control
ENV VITE_APP_META_SHA=$META_SHA
ENV VITE_APP_CLIENT_SHA=$CLIENT_SHA
ENV VITE_APP_CONTROL_SHA=$CONTROL_SHA
ENV VITE_APP_BUILD_TIME=$BUILD_TIME
RUN npm run build

# --- Stage 2: Rails + operator runtime
FROM ruby:3.4.2-slim

ENV LANG=C.UTF-8 \
    RAILS_LOG_TO_STDOUT=1 \
    BUNDLE_PATH=/usr/local/bundle

# OS deps. libpq for pg gem; build tools for native extensions; git for any
# git-based gems; tzdata for active_support.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev libyaml-dev tzdata git curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4 --retry 3

COPY . .

# Drop the built dashboard SPA into Rails' public/ root. ActionDispatch
# serves public/ before hitting the router, so /assets/<hash>.js etc. are
# fetched as files, while /api/* and /users/* still reach Rails. A
# catch-all route renders public/index.html so client-side Vue Router
# history-mode paths (/login, /dashboard) reload cleanly.
COPY --from=dashboard-build /client/dist/ /app/public/

RUN bundle exec bootsnap precompile --gemfile app/ lib/ operator/ bin/ config/ 2>&1 || true

EXPOSE 3001

# Default to the Rails server. Override `command:` in the operator Deployment.
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3001"]
