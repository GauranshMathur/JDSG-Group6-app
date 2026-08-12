// Average-load profile (F-8.5.2): the 90-9-1 mix arriving at a steady rate.
//
// `constant-arrival-rate` is the point of this file — an open model. The
// slice C suite used fixed VUs with think-time, which couples arrival rate to
// response time: the slower the app gets, the less load the test sends, and
// the percentiles flatter it. Here iterations arrive on schedule whether or
// not earlier ones have finished; if the app cannot keep up, k6 needs more
// VUs, and when maxVUs is exhausted it reports dropped_iterations — which is
// a capacity finding, not a harness error.
//
// Rates are per minute so the 90-9-1 split stays integral at small scales.
// Defaults are sized to sit at the edge of what milestone 8 measured the feed
// sustaining on a laptop; override to scale:
//
//   READERS_PER_MIN=108 ENGAGERS_PER_MIN=10 CREATORS_PER_MIN=2 \
//     script/stress-test load

import { readerJourney, engagerJourney, creatorJourney, cloudName } from "./lib.js";

const READERS_PER_MIN = Number(__ENV.READERS_PER_MIN || 54);
const ENGAGERS_PER_MIN = Number(__ENV.ENGAGERS_PER_MIN || 5);
const CREATORS_PER_MIN = Number(__ENV.CREATORS_PER_MIN || 1);
const DURATION = __ENV.LOAD_DURATION || "5m";

export const options = {
  cloud: { name: cloudName("load") },

  // Sessions persist across a VU's iterations, as a browser's would. k6's
  // default per-iteration cookie reset would force a fresh sign-in per
  // engager/creator iteration, which the app's sign-in rate limit (10 per
  // 3 minutes per IP) would refuse within the first minute.
  noCookiesReset: true,

  // Latency budgets per journey class, and an error gate: a run that serves
  // errors cannot end green no matter how fast the errors were (F-8.5.3).
  thresholds: {
    http_req_failed: ["rate<0.01"],
    checks: ["rate>0.99"],
    "http_req_duration{journey:reader}": ["p(95)<2000"],
    "http_req_duration{journey:engager}": ["p(95)<2000"],
    "http_req_duration{journey:creator}": ["p(95)<2000"],
  },

  scenarios: {
    readers: {
      executor: "constant-arrival-rate",
      rate: READERS_PER_MIN,
      timeUnit: "1m",
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 100,
      exec: "reader",
    },
    // Signed-in scenarios hold maxVUs == preAllocatedVUs deliberately: every
    // fresh VU costs one sign-in, and the app rate-limits sign-in to 10 per
    // 3 minutes per IP — its own protection, not to be worked around. Eight
    // signers per run stay inside it. If the arrival rate outruns these VUs,
    // k6 reports dropped_iterations, which is a capacity finding in itself.
    engagers: {
      executor: "constant-arrival-rate",
      rate: ENGAGERS_PER_MIN,
      timeUnit: "1m",
      duration: DURATION,
      preAllocatedVUs: 6,
      maxVUs: 6,
      exec: "engager",
    },
    creators: {
      executor: "constant-arrival-rate",
      rate: CREATORS_PER_MIN,
      timeUnit: "1m",
      duration: DURATION,
      preAllocatedVUs: 2,
      maxVUs: 2,
      exec: "creator",
    },
  },
};

export function reader() { readerJourney(); }
export function engager() { engagerJourney(); }
export function creator() { creatorJourney(); }
