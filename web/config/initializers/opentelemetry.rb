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
# Unset means off, and off means genuinely off — no SDK, no instrumentation, no
# spans created. That matters more than it sounds: the SDK's *own* default for
# OTEL_TRACES_EXPORTER is `otlp`, so configuring it unconditionally makes every
# process try to POST spans to localhost:4318, log an export failure for every
# batch, and — the expensive part — wrap every Active Record call in a span
# whether or not anything is listening. A seed run is thousands of writes, and
# it paid that cost on all of them.
#
# So: enable when an exporter is asked for, and in test, where the specs attach
# their own in-memory exporter and need a real tracer provider to attach it to.
# When it is off, OpenTelemetry.tracer_provider returns the API's no-op
# provider, so `tracer.in_span` in application code still works and costs
# nothing.

ENV["OTEL_TRACES_EXPORTER"] ||= "none"

tracing_requested = ENV["OTEL_TRACES_EXPORTER"] != "none"

if tracing_requested || Rails.env.test?
  # These requires stay here rather than at the top of the file, and Sonar's
  # rubydre:S7816 is right that this is unusual — it is also the whole point of
  # ADR 0009. Loading the SDK is what starts it; requiring it unconditionally
  # would mean every rails command paid for instrumentation nobody asked for,
  # which is a behaviour change rather than a tidy-up. The rule is refused here
  # deliberately, with the reason in the file rather than only on a dashboard.
  require "opentelemetry/sdk"
  require "opentelemetry/instrumentation/rails"

  # Each instrumentation announces itself at INFO on boot — ten lines in front
  # of every rails command and every CI log. Warnings and errors still surface.
  OpenTelemetry.logger = Logger.new($stdout, level: Logger::WARN)

  OpenTelemetry::SDK.configure do |c|
    c.service_name = "twitter-clone-web"
    c.service_version = ENV.fetch("APP_VERSION", "dev")

    # Rails, Action Pack, Action View, Active Record, Active Support, Active Job,
    # Active Storage and Rack — the request-level signals (duration, database
    # time, query counts) without hand-written instrumentation.
    c.use_all("OpenTelemetry::Instrumentation::Rails" => {})
  end
end
