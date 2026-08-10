# ADR 0008 — k6 generates the stress-test load

**Status:** Accepted
**Date:** 2026-08-10

## Context

Milestone 8 stresses the ranked feed with scripted, repeatable HTTP load. Something has to
generate that load, and the choice was between a plain Ruby script — zero new
dependencies, in the spirit of `script/smoke-test` — and [k6](https://k6.io/), a dedicated
load-testing tool.

The deciding context sits in the other repository: the infrastructure track's I-1g runs
load and latency tests against the app deployed on the local cluster, and k6 is the
leading candidate there. If the two repositories measure with different tools, their
numbers carry a permanent caveat: a latency difference between "app on my machine" and
"app on the cluster" could always be an artifact of how each tool measures rather than a
real difference.

## Decision

**k6 drives the stress scenarios in `script/stress-test`.** Scenarios are k6 JavaScript
checked into `web/script/`, run against a locally booted app; thresholds and summary
output (p50/p95/max) feed `docs/stress-testing.md` directly.

## Cost

This repository now carries a tool that is neither a gem nor vendored: k6 is an external
binary contributors must install, the first such requirement beyond Ruby and SQLite. Its
scenarios are JavaScript in a repository that has deliberately avoided a Node toolchain —
k6 embeds its own runtime, so no `package.json` appears, but the language boundary is
real. And CI, if it ever runs stress scenarios, needs the binary installed there too.

The zero-dependency script would have avoided all of that at the price of hand-rolling
percentile math and concurrency control, and of numbers that could never be compared
across the repository boundary without caveats.
