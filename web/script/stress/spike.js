// Spike profile (F-8.5.1): a viral moment — steady baseline, a sudden
// multiple of it, then back — watching whether the app survives the burst
// and how long it takes to recover once the burst ends.
//
// The aggregates cannot answer either question; read the time series (the
// terminal summary's timeline, or the Grafana Cloud run view): latency during
// the hold shows survival, latency after the drop shows whether the app
// recovers promptly or stays degraded working through a queue.
//
//   SPIKE_BASELINE_RPM=60 SPIKE_RPM=480 SPIKE_HOLD=90s SPIKE_RECOVERY=120s \
//     script/stress-test spike

import { feedRead, cloudName } from "./lib.js";

const BASELINE_RPM = Number(__ENV.SPIKE_BASELINE_RPM || 60);
const SPIKE_RPM = Number(__ENV.SPIKE_RPM || 480);

export const options = {
  cloud: { name: cloudName("spike") },

  // One gate: the burst may be slow, but the server has to keep answering.
  thresholds: {
    http_req_failed: ["rate<0.10"],
  },

  scenarios: {
    feed_spike: {
      executor: "ramping-arrival-rate",
      startRate: BASELINE_RPM,
      timeUnit: "1m",
      preAllocatedVUs: 30,
      maxVUs: 150,
      stages: [
        { target: BASELINE_RPM, duration: __ENV.SPIKE_BASELINE_BEFORE || "60s" },
        { target: SPIKE_RPM, duration: "10s" },
        { target: SPIKE_RPM, duration: __ENV.SPIKE_HOLD || "90s" },
        { target: BASELINE_RPM, duration: "10s" },
        { target: BASELINE_RPM, duration: __ENV.SPIKE_RECOVERY || "120s" },
      ],
      exec: "feed",
    },
  },
};

export function feed() { feedRead("spike"); }
