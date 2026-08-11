# Telemetry for milestone 8 (F-8.2), decided in ADR 0009.
#
# Instrumented once, exported anywhere: the same spans serve a local stress run
# and, later, whatever collector the cluster stands up. Which is why the
# exporter is configuration rather than code.
#
#   OTEL_TRACES_EXPORTER=console                 # print spans to stdout
#   OTEL_TRACES_EXPORTER=otlp \
#     OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # send to a collector
#
# Unset means "none": the SDK is configured, instrumentation is loaded, and
# nothing is emitted. That is the right default for a proof of concept whose
# usual state is nobody watching — a developer running the app should not need
# a collector, and CI should not pay to serialize spans no one reads.
#
# Specs are the exception: they attach their own in-memory exporter to assert
# the signals exist, which works because the SDK is still configured here.

require "opentelemetry/sdk"
require "opentelemetry/instrumentation/rails"

# Each instrumentation announces itself at INFO on boot — ten lines in front of
# every rails command and every CI log. Warnings and errors still surface.
OpenTelemetry.logger = Logger.new($stdout, level: Logger::WARN)

OpenTelemetry::SDK.configure do |c|
  c.service_name = "twitter-clone-web"
  c.service_version = ENV.fetch("APP_VERSION", "dev")

  # Rails, Action Pack, Action View, Active Record, Active Support, Active Job,
  # Active Storage and Rack — the request-level signals (duration, database
  # time, query counts) without hand-written instrumentation.
  c.use_all("OpenTelemetry::Instrumentation::Rails" => {})
end

Rails.application.config.x.tracer = OpenTelemetry.tracer_provider.tracer(
  "twitter-clone-web", ENV.fetch("APP_VERSION", "dev")
)
