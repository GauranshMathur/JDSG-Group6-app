// Milestone 8.5 slice D — shared journeys for the profile suite (F-8.5.1–3).
//
// Journeys, not endpoints: each function below walks the app the way one kind
// of visitor does, per the 90-9-1 rule in docs/design-principles.md. A reader
// pages the feed and opens things; an engager also writes engagement; a
// creator signs in and posts. The profiles (smoke, load, breakpoint, spike)
// decide how many of each arrive and how fast — this file only knows what a
// visit looks like.
//
// Every request is tagged with its journey and step, so thresholds can gate
// each class separately (`http_req_duration{journey:reader}` and friends) and
// a slow step is identifiable in the output rather than blended away.

import http from "k6/http";
import { check } from "k6";

export const BASE = __ENV.BASE_URL || "http://localhost:3000";

const MEGA_USER = __ENV.MEGA_USER || "";
const POST_IDS = (__ENV.POST_IDS || "").split(",").filter(Boolean);
const EMAILS = (__ENV.EMAILS || "").split(",").filter(Boolean);
const PASSWORD = __ENV.LOAD_PASSWORD || "loadtest1";
const SEARCH_TERMS = (__ENV.SEARCH_TERMS || "the,a,to,and,of").split(",");

// A free ngrok tunnel answers anything browser-shaped with an interstitial
// served as a 200; this header opts out. Harmless without a tunnel.
const BASE_HEADERS = { "ngrok-skip-browser-warning": "1" };

function params(journey, step) {
  return { headers: BASE_HEADERS, tags: { journey, step } };
}

// Status alone is not enough: an interstitial, a proxy error and a Rails
// "Blocked host" page can all be 200s with bodies. Every check asserts a
// marker only the intended page contains.
export function ok(res, marker) {
  return res.status === 200 && !!res.body && res.body.includes(marker);
}

// The layout's <meta name="csrf-token"> is the session-scoped token, valid
// for any form. Form inputs are NOT interchangeable: Rails issues per-form
// tokens scoped to one action+method, so scraping the first form on the page
// hands you (say) the sidebar sign-out form's token, and every other POST
// made with it is a silent 422. That exact mistake hid in the milestone 8
// suite — its churn writer never landed a single like.
function csrfToken(body) {
  const meta = body && body.match(/<meta name="csrf-token" content="([^"]+)"/);
  if (meta) return meta[1];
  const input = body && body.match(/name="authenticity_token"[^>]*value="([^"]+)"/);
  return input ? input[1] : "";
}

// Cookies are per-VU in k6, and so is module state — which makes this flag
// exactly "has this VU signed in". A session established on the first
// iteration serves every later one the VU runs.
let signedIn = false;

export function ensureSignedIn(journey) {
  if (signedIn) return true;
  if (EMAILS.length === 0) return false;

  const email = EMAILS[__VU % EMAILS.length];
  const form = http.get(`${BASE}/session/new`, params(journey, "sign_in_form"));
  const token = csrfToken(form.body);
  const res = http.post(
    `${BASE}/session`,
    { authenticity_token: token, email_address: email, password: PASSWORD },
    params(journey, "sign_in"),
  );

  // A failed sign-in also 302s (back to the form), so the landing page has to
  // prove the session exists — only a signed-in shell shows the sign-out
  // control.
  signedIn = ok(res, "Sign out");
  check(res, { "sign-in produced a session": () => signedIn });
  return signedIn;
}

function pickPost() {
  if (POST_IDS.length === 0) return null;
  // Spread by VU and iteration so concurrent VUs (possibly sharing a seeded
  // account) rarely act on the same post at the same moment.
  return POST_IDS[(__VU + __ITER) % POST_IDS.length];
}

// 90% of traffic: read the feed, page it, open a post, look something up.
export function readerJourney() {
  const feed = http.get(`${BASE}/`, params("reader", "feed"));
  check(feed, { "reader: feed": (r) => ok(r, "feed__") });

  // Page 2 goes through the same cached-feed path with an offset — never
  // load-tested before this suite.
  const page2 = http.get(`${BASE}/?page=1`, params("reader", "feed_page_2"));
  check(page2, { "reader: feed page 2": (r) => ok(r, "feed__") });

  const postId = pickPost();
  if (postId) {
    const detail = http.get(`${BASE}/posts/${postId}`, params("reader", "post_detail"));
    check(detail, { "reader: post detail": (r) => ok(r, "post-detail") });
  }

  if (__ITER % 2 === 0 && MEGA_USER) {
    const profile = http.get(`${BASE}/@${MEGA_USER}`, params("reader", "profile"));
    check(profile, { "reader: profile": (r) => ok(r, MEGA_USER) });
  } else {
    const term = SEARCH_TERMS[__ITER % SEARCH_TERMS.length];
    const search = http.get(`${BASE}/search?q=${encodeURIComponent(term)}`, params("reader", "search"));
    check(search, { "reader: search": (r) => ok(r, "Search") });
  }
}

// 9%: a reader who also likes and replies.
export function engagerJourney() {
  if (!ensureSignedIn("engager")) return;

  const feed = http.get(`${BASE}/`, params("engager", "feed"));
  check(feed, { "engager: feed": (r) => ok(r, "feed__") });

  const postId = pickPost();
  if (!postId) return;

  const detail = http.get(`${BASE}/posts/${postId}`, params("engager", "post_detail"));
  check(detail, { "engager: post detail": (r) => ok(r, "post-detail") });
  const token = csrfToken(detail.body);
  if (!token) return;

  const like = http.post(
    `${BASE}/posts/${postId}/like`,
    { authenticity_token: token },
    params("engager", "like"),
  );
  check(like, { "engager: like accepted": (r) => r.status === 200 });

  const reply = http.post(
    `${BASE}/posts/${postId}/replies`,
    { authenticity_token: token, "post[body]": `Load-test reply ${__VU}-${__ITER}` },
    params("engager", "reply"),
  );
  check(reply, { "engager: reply accepted": (r) => ok(r, "post-detail") });

  // Undo the like so a user/post pair never sticks and reruns stay
  // comparable. If a VU sharing this seeded account got here first the like
  // is already gone and Rails answers 404 — expected, so it must not count
  // against the error-rate gate, which exists to catch the server failing.
  // 302 is in the list because the callback judges every hop of the redirect
  // chain, not only the final response.
  http.post(
    `${BASE}/posts/${postId}/like`,
    { authenticity_token: token, _method: "delete" },
    Object.assign({ responseCallback: http.expectedStatuses(200, 302, 404) }, params("engager", "unlike")),
  );
}

// 1%: signs in and posts.
export function creatorJourney() {
  if (!ensureSignedIn("creator")) return;

  const feed = http.get(`${BASE}/`, params("creator", "feed"));
  check(feed, { "creator: feed": (r) => ok(r, "feed__") });
  const token = csrfToken(feed.body);
  if (!token) return;

  const res = http.post(
    `${BASE}/posts`,
    { authenticity_token: token, "post[body]": `Load-test post ${__VU}-${__ITER} #loadtest` },
    params("creator", "post"),
  );
  check(res, { "creator: post accepted": (r) => ok(r, "feed__") });
}

// One bare feed read — the unit the capacity profiles (breakpoint, spike)
// hammer, because the feed is the page the milestone 8 findings are about.
export function feedRead(journey) {
  const res = http.get(`${BASE}/`, params(journey, "feed"));
  check(res, { "feed served the app": (r) => ok(r, "feed__") });
}

// Names the run in the Grafana Cloud k6 dashboard; RUN_LABEL tells runs of
// the same profile apart.
export function cloudName(profile) {
  const label = __ENV.RUN_LABEL ? ` — ${__ENV.RUN_LABEL}` : "";
  return `twitter-clone ${profile}${label}`;
}
