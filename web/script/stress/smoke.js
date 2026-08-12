// Smoke profile (F-8.5.1): is every journey walkable at all. One VU per
// journey, a few iterations, and strict gates — any request error or failed
// check fails the run. Cheap enough to run before any long profile, so a
// broken fixture or a dead route costs one minute instead of ten.

import { readerJourney, engagerJourney, creatorJourney, cloudName } from "./lib.js";

export const options = {
  cloud: { name: cloudName("smoke") },

  // k6 wipes each VU's cookie jar between iterations by default, which would
  // sign the engager and creator out the moment their first iteration ended —
  // and the app rate-limits sign-in (10 per 3 minutes per IP), so
  // re-authenticating per iteration is not an option. Sessions persist, as a
  // browser's would.
  noCookiesReset: true,

  thresholds: {
    http_req_failed: ["rate==0"],
    checks: ["rate==1.0"],
  },

  scenarios: {
    reader: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 3,
      maxDuration: "1m",
      exec: "reader",
    },
    engager: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 2,
      maxDuration: "1m",
      startTime: "5s",
      exec: "engager",
    },
    creator: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 2,
      maxDuration: "1m",
      startTime: "10s",
      exec: "creator",
    },
  },
};

export function reader() { readerJourney(); }
export function engager() { engagerJourney(); }
export function creator() { creatorJourney(); }
