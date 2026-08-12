// Breakpoint profile (F-8.5.1): climb the arrival rate on the feed until the
// SLOs break — the knee and the failure mode, the two things milestone 8's
// fixed five VUs could never find.
//
// The ramp aborts once clearly past collapse (errors above 10%, or p95 past
// 15 s, each given time to stop being a blip) rather than hammering a dead
// server through the remaining stages. The knee is read from the time series:
// the last arrival rate where latency was still flat.
//
//   BREAKPOINT_START_RPM=60 BREAKPOINT_MAX_RPM=600 BREAKPOINT_STAGE_SECONDS=60 \
//     script/stress-test breakpoint

import { feedRead, cloudName } from "./lib.js";

const START_RPM = Number(__ENV.BREAKPOINT_START_RPM || 60);
const MAX_RPM = Number(__ENV.BREAKPOINT_MAX_RPM || 600);
const STAGE_SECONDS = Number(__ENV.BREAKPOINT_STAGE_SECONDS || 60);
const STEPS = 5;

// A free Grafana Cloud project allows 100 VUs per test, so the pool stops at
// 90. That is not a small pool for this ramp: an open model needs roughly
// rate x latency VUs, so 600/min against a 2-second feed occupies about 20.
// The pool only saturates once responses pass ~9 seconds — by which point the
// abort thresholds below have already fired, and dropped_iterations is part of
// the finding rather than a harness limit. Raise it for a local run
// (BREAKPOINT_MAX_VUS=300) when pushing past the cloud ceiling.
const MAX_VUS = Number(__ENV.BREAKPOINT_MAX_VUS || 90);

const stages = [];
for (let i = 1; i <= STEPS; i++) {
  stages.push({
    target: Math.round(START_RPM + ((MAX_RPM - START_RPM) * i) / STEPS),
    duration: `${STAGE_SECONDS}s`,
  });
}

export const options = {
  cloud: { name: cloudName("breakpoint") },

  thresholds: {
    http_req_failed: [{ threshold: "rate<0.10", abortOnFail: true, delayAbortEval: "30s" }],
    http_req_duration: [{ threshold: "p(95)<15000", abortOnFail: true, delayAbortEval: "60s" }],
  },

  scenarios: {
    feed_ramp: {
      executor: "ramping-arrival-rate",
      startRate: START_RPM,
      timeUnit: "1m",
      preAllocatedVUs: Math.min(50, MAX_VUS),
      maxVUs: MAX_VUS,
      stages,
      exec: "feed",
    },
  },
};

export function feed() { feedRead("breakpoint"); }
