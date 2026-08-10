# ADR 0009 — Telemetry is OpenTelemetry, not hand-rolled log lines

**Status:** Accepted
**Date:** 2026-08-10

## Context

Milestone 8 needs the app to be measurable: per-request duration, database time and query
counts, and feed-specific signals — rebuild duration, item count, cache hit or miss. The
cheap option was structured log lines subscribed to `ActiveSupport::Notifications`: zero
dependencies, greppable, entirely sufficient for a single stress run read by a human.

The context that outgrew it is, again, the infrastructure track: its observability plan is
Prometheus and Grafana in-cluster (the CloudWatch stand-in), and I-1g wants to watch the
same signals under cluster load that milestone 8 watches locally. Hand-rolled log lines
would be instrumented once for milestone 8 and then re-instrumented for the cluster;
OpenTelemetry is instrumented once and exported anywhere.

## Decision

**The app is instrumented with OpenTelemetry.** The Ruby SDK with Rails and Active Record
auto-instrumentation provides the request-level signals; custom instrumentation in
`RankedFeed` adds the feed signals (rebuild span with item count, cache hit/miss). During
local stress runs the data goes to an OTLP endpoint or the console exporter — whichever
the run needs; on the cluster, the same instrumentation feeds whatever collector the
infrastructure track stands up. The exporter is configuration, not code.

## Cost

This is the largest dependency the app has taken since authentication was declined a gem:
an SDK, an API, and per-library instrumentation gems, all of which move at their own
release cadence and load at boot on every process — including ones that will never export
a span. It is a genuine framework adoption in a proof of concept that has otherwise held
the line at "boring, conventional Rails", and it front-loads infrastructure-track needs
into an app-track milestone on the bet that the instrumentation only has to be written
once. If that bet is wrong — if the cluster work wants different signals — the log-line
approach would have been cheaper to throw away.
