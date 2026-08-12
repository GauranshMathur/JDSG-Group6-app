// Milestone 8 slice C — k6 stress scenarios (F-8.3), per ADR 0008.
//
// Four scenarios, run in sequence rather than together, because they would
// otherwise measure each other: the churn scenario deliberately busts the feed
// cache, which is exactly what the warm scenario must not have happening to it.
// startTime staggers them; each reports its own p50/p95/max.
//
//   feed_warm    steady reads against a warm cache — the common case
//   feed_churn   the same reads while a writer likes posts, so the cache keeps
//                being invalidated and readers pay for rebuilds
//   profile      a mega-account's profile page
//   search       a query against the seeded volume
//
// Run it through script/stress-test, which discovers the mega-account and a
// post id from the database and passes them in.

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend } from "k6/metrics";

const BASE = __ENV.BASE_URL || "http://localhost:3000";
const MEGA_USER = __ENV.MEGA_USER || "";
const LIKE_POST_ID = __ENV.LIKE_POST_ID || "";
const EMAIL = __ENV.LOAD_EMAIL || "";
const PASSWORD = __ENV.LOAD_PASSWORD || "loadtest1";
const SEARCH_TERM = __ENV.SEARCH_TERM || "the";

// Sent on every request. A free ngrok tunnel answers an interstitial warning
// page to anything that looks like a browser, and that page is a 200 — so
// without this header a run through a tunnel can report four green scenarios
// having measured nothing but ngrok. Harmless when there is no tunnel.
const PARAMS = { headers: { "ngrok-skip-browser-warning": "1" } };

// Checking the status alone is not enough for the same reason: an interstitial,
// a proxy error or a Rails "Blocked host" page are all served with a body, and
// some with a 200. Each scenario asserts something only its own page contains.
function ok(res, marker) {
  return res.status === 200 && res.body.includes(marker);
}

// One trend per scenario. k6's built-in http_req_duration aggregates every
// request in the run, which would blend a 2-second feed page into the same
// number as a 60ms profile page and describe neither.
const feedWarm = new Trend("scenario_feed_warm", true);
const feedChurn = new Trend("scenario_feed_churn", true);
const profile = new Trend("scenario_profile", true);
const search = new Trend("scenario_search", true);

export const options = {
  // Names the run in the Grafana Cloud k6 dashboard. Without it every upload
  // arrives called "scenarios.js", and the point of uploading is being able to
  // tell one run from another later.
  cloud: {
    name: `twitter-clone feed stress${__ENV.RUN_LABEL ? ` — ${__ENV.RUN_LABEL}` : ""}`,
  },

  // The writer's session must survive its iterations: k6 wipes each VU's
  // cookie jar between iterations by default, and the app rate-limits sign-in.
  noCookiesReset: true,

  // Thresholds are recorded, not enforced: this milestone measures and does not
  // fix, so a slow feed is the finding rather than a failure. They exist so the
  // summary marks which numbers are out of line.
  thresholds: {
    scenario_feed_warm: ["p(95)<2000"],
    scenario_feed_churn: ["p(95)<8000"],
    scenario_profile: ["p(95)<500"],
    scenario_search: ["p(95)<1000"],
  },
  scenarios: {
    feed_warm: {
      executor: "constant-vus",
      vus: 5,
      duration: "30s",
      exec: "readFeed",
      startTime: "0s",
    },
    feed_churn_readers: {
      executor: "constant-vus",
      vus: 5,
      duration: "30s",
      exec: "readFeedUnderChurn",
      startTime: "35s",
    },
    feed_churn_writer: {
      executor: "constant-vus",
      vus: 1,
      duration: "30s",
      exec: "likeAndUnlike",
      startTime: "35s",
    },
    profile_page: {
      executor: "constant-vus",
      vus: 5,
      duration: "20s",
      exec: "readProfile",
      startTime: "70s",
    },
    search_page: {
      executor: "constant-vus",
      vus: 5,
      duration: "20s",
      exec: "readSearch",
      startTime: "95s",
    },
  },
};

// Rails protects non-GET requests with an authenticity token, so a writer has
// to behave like a browser. The token comes from the layout's
// <meta name="csrf-token"> — the session-scoped token valid for any form.
// Form inputs are not interchangeable: Rails issues per-form tokens scoped to
// one action+method, so scraping a form's token and posting it elsewhere is a
// silent 422. The first version of this file did exactly that, and worse,
// signed in during setup() — whose cookie jar VUs never see — so the churn
// writer held no session, found no token on the signed-out page, and returned
// without ever liking anything. The churn scenario measured an untouched warm
// cache. Recorded in docs/stress-testing.md; the writer now signs in in its
// own VU and proves each like landed.
function csrfToken(body) {
  const meta = body && body.match(/<meta name="csrf-token" content="([^"]+)"/);
  if (meta) return meta[1];
  const input = body && body.match(/name="authenticity_token"[^>]*value="([^"]+)"/);
  return input ? input[1] : "";
}

// Module state and cookies are both per-VU, so this is "has this VU signed in".
let signedIn = false;

function ensureSignedIn() {
  if (signedIn) return true;
  if (!EMAIL) return false;

  const form = http.get(`${BASE}/session/new`, PARAMS);
  const token = csrfToken(form.body);
  const res = http.post(`${BASE}/session`, {
    authenticity_token: token,
    email_address: EMAIL,
    password: PASSWORD,
  }, PARAMS);

  // A failed sign-in also lands on a 200 page (the form, via redirect), so
  // only the signed-in shell's sign-out control proves a session exists.
  signedIn = ok(res, "Sign out");
  return signedIn;
}

export function readFeed() {
  const res = http.get(`${BASE}/`, PARAMS);
  feedWarm.add(res.timings.duration);
  check(res, { "feed served the app": (r) => ok(r, "feed__") });
  sleep(0.5);
}

export function readFeedUnderChurn() {
  const res = http.get(`${BASE}/`, PARAMS);
  feedChurn.add(res.timings.duration);
  check(res, { "feed served the app under churn": (r) => ok(r, "feed__") });
  sleep(0.5);
}

// The writer's own latency is not the measurement — the readers' is. This VU
// exists to keep RankedFeed.bust_cache firing, which is what a real timeline
// does continuously and what turns a cache hit into a rebuild.
export function likeAndUnlike() {
  if (!LIKE_POST_ID || !ensureSignedIn()) return;

  const page = http.get(`${BASE}/posts/${LIKE_POST_ID}`, PARAMS);
  const token = csrfToken(page.body);
  if (!token) return;

  const like = http.post(`${BASE}/posts/${LIKE_POST_ID}/like`, { authenticity_token: token }, PARAMS);
  check(like, { "writer: like landed": (r) => r.status === 200 });
  sleep(1);
  http.post(`${BASE}/posts/${LIKE_POST_ID}/like`, {
    authenticity_token: token,
    _method: "delete",
  }, PARAMS);
  sleep(1);
}

export function readProfile() {
  if (!MEGA_USER) return;

  const res = http.get(`${BASE}/@${MEGA_USER}`, PARAMS);
  profile.add(res.timings.duration);
  check(res, { "profile served the app": (r) => ok(r, MEGA_USER) });
  sleep(0.5);
}

export function readSearch() {
  const res = http.get(`${BASE}/search?q=${encodeURIComponent(SEARCH_TERM)}`, PARAMS);
  search.add(res.timings.duration);
  check(res, { "search served the app": (r) => ok(r, "Search") });
  sleep(0.5);
}

