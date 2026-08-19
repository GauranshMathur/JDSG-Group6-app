// The review profile — load-side guards for the 2026-08-18 architecture
// review (docs/architecture-reviews/2026-08-18.md), built BEFORE the fixes so
// each fix lands against a measurement rather than an argument.
//
// Each scenario names the finding it guards. Two kinds of outcome are
// expected today, and both are the point:
//
//   RED today, green after the fix   hostile_paging — finding 4's two 500s
//   measured today, compared after   tag/search latency (1), profile paging
//                                    (5), reply and archive-like churn (6)
//   green today, kept green          auth_rate_limit (3) — the limiter works
//                                    over HTTP; only the spec suite cannot
//                                    see it. This guard is what notices if a
//                                    fix to finding 3 breaks the real thing.
//
// Scenarios run in sequence, not together — they would otherwise measure each
// other (the churn writers deliberately bust the cache the warm scenario must
// see intact). auth_rate_limit runs LAST and then poisons sign-in from this
// IP for ~3 minutes — its job is to trip the limiter — so leave a gap before
// running any signing profile (smoke, load, scenarios) afterwards.
//
// Run through script/stress-test, which discovers the fixtures:
//   script/stress-test review

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";
import { BASE, ok, csrfToken, ensureSignedIn, cloudName } from "./lib.js";

const MEGA_USER = __ENV.MEGA_USER || "";
const HOT_TAG = __ENV.HOT_TAG || "";
const POST_IDS = (__ENV.POST_IDS || "").split(",").filter(Boolean);
const ARCHIVE_POST_ID = __ENV.ARCHIVE_POST_ID || "";
const SEARCH_TERMS = (__ENV.SEARCH_TERMS || "the,a,to,and,of").split(",");

const PARAMS = { headers: { "ngrok-skip-browser-warning": "1" } };

// One trend per question, so a slow tag page cannot hide inside an average
// with the warm feed.
const feedWarm = new Trend("review_feed_warm", true);
const tagPage = new Trend("review_tag_page", true);
const searchPage = new Trend("review_search_page", true);
const profilePage = new Trend("review_profile_page", true);
const feedReplyChurn = new Trend("review_feed_reply_churn", true);
const feedArchiveChurn = new Trend("review_feed_archive_churn", true);
const serverErrors = new Counter("review_server_errors");
const rateLimited = new Counter("review_rate_limited");

export const options = {
  cloud: { name: cloudName("review") },
  noCookiesReset: true,

  thresholds: {
    // Finding 4: a hostile page parameter must never be a 500. RED today —
    // /?page=-1 and /@user?page=-1 both raise ArgumentError.
    review_server_errors: ["count==0"],

    // Finding 3: the brute-force limiter must actually refuse over HTTP.
    review_rate_limited: ["count>0"],

    // Budgets are the post-fix targets. The warm feed is the reference the
    // others are read against; the churn trends matter as a COMPARISON with
    // it (finding 6: after the fix, replies and archive likes must cost
    // readers nothing, so churn ≈ warm).
    review_feed_warm: ["p(95)<500"],
    review_tag_page: ["p(95)<500"],
    review_search_page: ["p(95)<500"],
    review_profile_page: ["p(95)<500"],
    review_feed_reply_churn: ["p(95)<1000"],
    review_feed_archive_churn: ["p(95)<1000"],
  },

  scenarios: {
    feed_warm: {
      executor: "constant-vus", vus: 5, duration: "20s",
      exec: "readFeedWarm", startTime: "0s",
    },
    tag_page: {
      executor: "constant-vus", vus: 5, duration: "30s",
      exec: "readTag", startTime: "25s",
    },
    search_page: {
      executor: "constant-vus", vus: 5, duration: "30s",
      exec: "readSearch", startTime: "60s",
    },
    profile_pages: {
      executor: "constant-vus", vus: 5, duration: "30s",
      exec: "readProfilePages", startTime: "95s",
    },
    reply_churn_readers: {
      executor: "constant-vus", vus: 5, duration: "30s",
      exec: "readFeedUnderReplyChurn", startTime: "130s",
    },
    reply_churn_writer: {
      executor: "constant-vus", vus: 1, duration: "30s",
      exec: "writeReplies", startTime: "130s",
    },
    archive_churn_readers: {
      executor: "constant-vus", vus: 5, duration: "30s",
      exec: "readFeedUnderArchiveChurn", startTime: "165s",
    },
    archive_churn_writer: {
      executor: "constant-vus", vus: 1, duration: "30s",
      exec: "likeArchivePost", startTime: "165s",
    },
    hostile_paging: {
      executor: "per-vu-iterations", vus: 1, iterations: 3,
      maxDuration: "30s", exec: "hostilePaging", startTime: "200s",
    },
    auth_rate_limit: {
      executor: "per-vu-iterations", vus: 1, iterations: 12,
      maxDuration: "60s", exec: "hammerSignIn", startTime: "215s",
    },
  },
};

// --- Reference ---------------------------------------------------------

export function readFeedWarm() {
  const res = http.get(`${BASE}/`, PARAMS);
  feedWarm.add(res.timings.duration);
  check(res, { "warm: feed": (r) => ok(r, "feed__") });
  sleep(0.5);
}

// --- Finding 1: tag and search have the N+1 and no guard ---------------

export function readTag() {
  if (!HOT_TAG) return;
  const res = http.get(`${BASE}/tags/${encodeURIComponent(HOT_TAG)}`, PARAMS);
  tagPage.add(res.timings.duration);
  check(res, {
    "tag: page served": (r) => ok(r, `#${HOT_TAG}`),
    "tag: has posts": (r) => countPosts(r) > 0,
  });
  sleep(0.5);
}

function countPosts(res) {
  const m = res.body && res.body.match(/<article class="post"/g);
  return m ? m.length : 0;
}

// --- Findings 1 and 2: search latency, and case parity -----------------

// Finding 2 is a portability defect: Post.search folds case on neither side,
// so "case-insensitive" is currently a property of SQLite's LIKE, not of the
// code. On SQLite both casings below return the same rows and this check is
// green; on PostgreSQL the uppercased query returns nothing and it goes red —
// which is exactly when it needs to. The check rides along so the parity
// claim (F-6.3) is exercised on every run from now until the switch.
export function readSearch() {
  const term = SEARCH_TERMS[__ITER % SEARCH_TERMS.length];
  const res = http.get(`${BASE}/search?q=${encodeURIComponent(term)}`, PARAMS);
  searchPage.add(res.timings.duration);
  check(res, { "search: page served": (r) => ok(r, "Search") });

  if (__ITER % 3 === 0) {
    const upper = http.get(`${BASE}/search?q=${encodeURIComponent(term.toUpperCase())}`, PARAMS);
    check(upper, {
      "search: case parity (F-6.3)": (r) => countPosts(r) === countPosts(res) && countPosts(res) > 0,
    });
  }
  sleep(0.5);
}

// --- Finding 5: ProfileFeed materialises the whole archive -------------

// Every page of the mega-account costs a full materialisation today, so page
// 5 costs what page 1 costs — and both cost the account's entire history.
// After the fix the cost tracks the page. The trend spans pages 1–5 so the
// number describes profile *paging*, not just the front page.
export function readProfilePages() {
  if (!MEGA_USER) return;
  const page = __ITER % 5;
  const res = http.get(`${BASE}/@${MEGA_USER}?page=${page}`, PARAMS);
  profilePage.add(res.timings.duration);
  check(res, { "profile: page served": (r) => ok(r, MEGA_USER) });
  sleep(0.5);
}

// --- Finding 6: invalidation is broader than the ranking ---------------

// A reply can never appear in the ranked window (it is not top_level), and a
// like on a post outside the window cannot move anything — yet both bust the
// ordering today, forcing rebuilds that produce byte-identical results. The
// readers' latency is the measurement; the writers exist to keep the events
// firing. After the fix, both churn trends should sit at warm-feed levels.

export function readFeedUnderReplyChurn() {
  const res = http.get(`${BASE}/`, PARAMS);
  feedReplyChurn.add(res.timings.duration);
  check(res, { "reply churn: feed": (r) => ok(r, "feed__") });
  sleep(0.5);
}

export function writeReplies() {
  if (POST_IDS.length === 0 || !ensureSignedIn("review_writer")) return;
  const postId = POST_IDS[__ITER % POST_IDS.length];
  const page = http.get(`${BASE}/posts/${postId}`, PARAMS);
  const token = csrfToken(page.body);
  if (!token) return;
  const reply = http.post(
    `${BASE}/posts/${postId}/replies`,
    { authenticity_token: token, "post[body]": `Review-profile reply ${__VU}-${__ITER}` },
    PARAMS,
  );
  check(reply, { "reply churn: reply landed": (r) => ok(r, "post-detail") });
  sleep(1);
}

export function readFeedUnderArchiveChurn() {
  const res = http.get(`${BASE}/`, PARAMS);
  feedArchiveChurn.add(res.timings.duration);
  check(res, { "archive churn: feed": (r) => ok(r, "feed__") });
  sleep(0.5);
}

export function likeArchivePost() {
  if (!ARCHIVE_POST_ID || !ensureSignedIn("review_writer")) return;
  const page = http.get(`${BASE}/posts/${ARCHIVE_POST_ID}`, PARAMS);
  const token = csrfToken(page.body);
  if (!token) return;
  http.post(`${BASE}/posts/${ARCHIVE_POST_ID}/like`, { authenticity_token: token }, PARAMS);
  sleep(1);
  http.post(`${BASE}/posts/${ARCHIVE_POST_ID}/like`, {
    authenticity_token: token, _method: "delete",
  }, Object.assign({ responseCallback: http.expectedStatuses(200, 302, 404) }, PARAMS));
  sleep(1);
}

// --- Finding 4: nothing owns the page parameter ------------------------

// Every URL a stranger can type must come back as a page or a clean 4xx —
// never a 500. Today /?page=-1 and /@user?page=-1 both reach
// entries.drop(-20) and raise. The garbage cursors and the missing post are
// here because they are the same class of input, already handled — the
// scenario pins them so a fix to the page parameter cannot regress them.
export function hostilePaging() {
  const urls = [
    `${BASE}/?page=-1`,
    `${BASE}/?page=0`,
    `${BASE}/?page=99999`,
    `${BASE}/@${MEGA_USER}?page=-1`,
    `${BASE}/@${MEGA_USER}?page=99999`,
    `${BASE}/tags/${encodeURIComponent(HOT_TAG)}?after=garbage`,
    `${BASE}/search?q=x&after=garbage`,
    `${BASE}/posts/999999999`,
  ];
  for (const url of urls) {
    // 4xx is an acceptable answer to a hostile URL; 5xx never is. The
    // callback keeps expected 4xxs out of http_req_failed so the one gate
    // that fails is the one that means it.
    const res = http.get(url, Object.assign(
      { responseCallback: http.expectedStatuses({ min: 200, max: 499 }) }, PARAMS,
    ));
    if (res.status >= 500) serverErrors.add(1);
    check(res, { [`hostile: ${url.replace(BASE, "")} not 5xx`]: (r) => r.status < 500 });
  }
  sleep(0.5);
}

// --- Finding 3: the rate limiter, reached at last ----------------------

// The spec suite reaches none of the three rate_limit declarations because
// the test cache store is :null_store. Over HTTP the store is real, so
// hammering sign-in with a wrong password MUST eventually be refused — the
// app answers with a redirect to the form and "Try again later.". Twelve
// attempts against a 10-per-3-minutes limit leaves no room for doubt.
export function hammerSignIn() {
  const form = http.get(`${BASE}/session/new`, PARAMS);
  const token = csrfToken(form.body);
  const res = http.post(`${BASE}/session`, {
    authenticity_token: token,
    email_address: "hammer@loadtest.example.com",
    password: "definitely-wrong",
  }, PARAMS);
  if (res.status < 500 && res.body && res.body.includes("Try again later.")) {
    rateLimited.add(1);
  }
  check(res, { "hammer: not a 5xx": (r) => r.status < 500 });
}
