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

// One trend per scenario. k6's built-in http_req_duration aggregates every
// request in the run, which would blend a 2-second feed page into the same
// number as a 60ms profile page and describe neither.
const feedWarm = new Trend("scenario_feed_warm", true);
const feedChurn = new Trend("scenario_feed_churn", true);
const profile = new Trend("scenario_profile", true);
const search = new Trend("scenario_search", true);

export const options = {
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
// to behave like a browser: fetch a form, read the token out of it, post with
// it. The token is per-session and stays valid for the session, so it is read
// once per VU rather than per request.
function csrfToken(body) {
  const match = body.match(/name="authenticity_token"[^>]*value="([^"]+)"/);
  return match ? match[1] : "";
}

function signIn() {
  const form = http.get(`${BASE}/session/new`);
  const token = csrfToken(form.body);

  const res = http.post(`${BASE}/session`, {
    authenticity_token: token,
    email_address: EMAIL,
    password: PASSWORD,
  });

  return { signedIn: res.status === 200 || res.status === 302 };
}

export function readFeed() {
  const res = http.get(`${BASE}/`);
  feedWarm.add(res.timings.duration);
  check(res, { "feed 200": (r) => r.status === 200 });
  sleep(0.5);
}

export function readFeedUnderChurn() {
  const res = http.get(`${BASE}/`);
  feedChurn.add(res.timings.duration);
  check(res, { "feed 200 under churn": (r) => r.status === 200 });
  sleep(0.5);
}

// The writer's own latency is not the measurement — the readers' is. This VU
// exists to keep RankedFeed.bust_cache firing, which is what a real timeline
// does continuously and what turns a cache hit into a rebuild.
export function likeAndUnlike() {
  if (!EMAIL || !LIKE_POST_ID) return;

  const form = http.get(`${BASE}/posts/${LIKE_POST_ID}`);
  const token = csrfToken(form.body);
  if (!token) return;

  http.post(`${BASE}/posts/${LIKE_POST_ID}/like`, { authenticity_token: token });
  sleep(1);
  http.post(`${BASE}/posts/${LIKE_POST_ID}/like`, {
    authenticity_token: token,
    _method: "delete",
  });
  sleep(1);
}

export function readProfile() {
  if (!MEGA_USER) return;

  const res = http.get(`${BASE}/@${MEGA_USER}`);
  profile.add(res.timings.duration);
  check(res, { "profile 200": (r) => r.status === 200 });
  sleep(0.5);
}

export function readSearch() {
  const res = http.get(`${BASE}/search?q=${encodeURIComponent(SEARCH_TERM)}`);
  search.add(res.timings.duration);
  check(res, { "search 200": (r) => r.status === 200 });
  sleep(0.5);
}

export function setup() {
  if (EMAIL) signIn();
  return {};
}
