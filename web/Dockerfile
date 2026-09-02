# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t web .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name web web

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.12
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
# When switching to PostgreSQL, add libpq5 here and libpq-dev to the build stage.
#
# The upgrade matters as much as the install: the ruby image is rebuilt on its
# own schedule, so its Debian packages trail security updates by weeks even on
# the newest tag. Without this, the image scan fails on CVEs in libssl, gnutls
# and friends that are already fixed upstream and that we install nothing to get.
RUN apt-get update -qq && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# BUNDLE_WITHOUT excludes test as well as development: RSpec, RuboCop and Brakeman
# sit in "group :development, :test", and a gem is only skipped when every group
# it belongs to is excluded. Omitting test here would ship the whole test
# toolchain into the production image.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

# The superseded resolv specification goes with the install. resolv 0.3.1 is a
# *default* gem in this base image and carries CVE-2026-80212; the Gemfile pins
# 0.7.2, which is what the application loads, but the old specification stays on
# disk and is what an image scanner reads. Removing it makes the image describe
# what it actually runs. Only the specification goes — the stdlib source stays,
# and the bundled 0.7.2 is what `require "resolv"` resolves to.
RUN bundle install && \
    rm -f /usr/local/lib/ruby/gems/*/specifications/default/resolv-0.3.1.gemspec && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Rails exposes /up, which returns 200 once the app has booted without raising.
# CI waits on this before pointing the DAST scanner at the container.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=5 \
    CMD curl -fsS http://localhost/up || exit 1

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
