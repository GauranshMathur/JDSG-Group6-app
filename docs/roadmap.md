# Roadmap

Ordered. Each milestone is a shippable slice; we plan the details of a milestone when we
reach it, not before. **Each milestone is built, tested, and merged before the next one
starts** — a milestone is not done until its pull request is green and merged into the default
branch. Each milestone gets its own branch and its own pull request; do not stack milestones
on a single branch.

### App milestones

| # | Milestone | Status |
| --- | --- | --- |
| 0 | Repo scaffolding — Rails app in `web/`, Docker, CI | **Done** |
| 1 | **The feed** — post creation and timeline rendering | **Done** |
| 2 | **Authentication** — sign up, sign in, sign out, sessions | **Done** |
| 3 | **Post ownership and CRUD** — posts belong to users; edit and delete your own | **Done** |
| 4 | **Navigation and profiles** — sidebar shell, profile pages, edit your profile | **Done** |
| 5 | **Engagement and hashtags** — likes, reposts, replies, `#tag` pages | **Done** |
| 5.5 | **Feed v2** — reposts in timeline, ranked feed, load-test seed data | **Done** |
| 6 | **Search** — find posts and people from the sidebar | **Done** |
| 6.5 | **Feed caching** — cache the ranked feed, warm on boot, invalidate on engagement | **Done** |
| 7 | **Images** — profile avatars and image uploads on posts | **Done** |
| 8 | **Stress and telemetry** — shaped seed data at scale, basic telemetry, stress the ranked feed, write down what breaks | **Done** — measured at 10k; the 100k run moved to 8.5 |
| 8.5 | **Load-testing harness v2** — open-model k6 profiles, production-shape target, Grafana Cloud reading surface; then the measurements and the feed fix | **Planned** |

### Infrastructure

Tracked in its own repository, [JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra), and not sequenced against the app
milestones. Three changes here are owed to that work — PostgreSQL, a shared cache, and S3 for
Active Storage — and are made when they block, not before.

Milestones 0 and 1 were built together, since a feed needs an app to live in.

Milestones 2–6 (including 5.5) are the completed block of work: authentication, full CRUD on
posts, profiles, engagement with hashtags, ranked feed, and search. They were built
separately because each is independently shippable, and because a single change touching
auth, ownership, navigation, engagement, tagging and search at once is not reviewable.

## Milestone 1 — The Feed

**Built.** Per-requirement status lives in [`REQUIREMENTS.md`](../REQUIREMENTS.md) (F-1.x).

What shipped:

- `Post` — body (1–280 chars) and author name (≤50 chars, defaulting to `anonymous`).
- A composer form, with validation errors rendered inline.
- A reverse-chronological timeline, 20 posts per page.
- Turbo Stream response on create, so a new post is prepended without a page reload.
- Keyset (cursor) pagination with a "Load older posts" link.
- 27 model and request specs.

**Deliberately not built**

- Follow graph and personalised ranking — this is a global timeline.
- Likes, replies, reposts, media, mentions, hashtags.
- Authentication. Authorship is a free-text name on the post; milestone 2 replaces it with a
  `belongs_to :user` association.

**Design decisions made along the way**

- *Timeline read model* — query-on-read. Fan-out-on-write is deferred until a follow graph
  exists to fan out to (milestone 4).
- *Pagination* — keyset rather than offset. An offset page shifts as new posts arrive at the
  head of the timeline, which repeats and skips rows; a cursor of `(created_at, id)` does not.
- *Ordering tie-break* — `created_at DESC, id DESC`. Ordering on `created_at` alone is not a
  total order, so posts written in the same tick could swap places between requests and be
  paginated past. The index matches the sort, so it serves both.

## Milestones 2–6 — the plan

Written before any of it is built, so the shape is agreed rather than discovered. Each
milestone is a pull request or a small series of them, and each ends with the app working.

Requirement IDs referenced here are defined in [`REQUIREMENTS.md`](../REQUIREMENTS.md).

### Milestone 2 — Authentication (F-2.x) — **built**

Per-requirement status is in [`REQUIREMENTS.md`](../REQUIREMENTS.md) (F-2.x). What shipped:

- `User` with `has_secure_password`, and `Session` rows behind a signed cookie.
- Registration (ours), sign in, sign out and password reset (the generator's).
- `Current.user`, and `allow_unauthenticated_access only: :index` on the feed.
- A signed-out visitor reads the timeline and sees a sign-in prompt where the composer would
  be. This was written down as F-3.6 for milestone 3, but guarding `create` without it would
  have shown a form whose only effect was to bounce you to sign in.
- A plain masthead with sign in / sign up / sign out, replaced by the sidebar in milestone 4.
- 36 new specs, and one behaviour worth naming: sign-out is asserted to destroy the `Session`
  row, not just clear the cookie.

**Two things landed that the plan below did not expect.** The generator applies `rate_limit`
to sign-in and password reset, so N-5.3 moved from deferred to met without being asked for —
though it counts through `Rails.cache`, which is per-process here. And posts still carry a
free-text `author_name` while now requiring an account to write, which is an odd pairing:
you must sign in, then type whatever name you like. Milestone 3 removes the column.

The original plan, unchanged:

Rails 8 ships an authentication generator — `bin/rails generate authentication` — which
produces a `User` model, a `Session` model, sign-in, sign-out and password reset. No gem, no
Devise. That matches the "boring, conventional Rails" rule, and it is one fewer dependency to
inherit. See [ADR 0001](adr/0001-authentication.md).

- `User` — email address and `has_secure_password`, unique case-insensitive email.
- Registration, sign in, sign out. Sessions in a signed cookie backed by a `Session` record,
  so sign-out can revoke server-side rather than only clearing the browser.
- `Current.user` for the request-scoped current user.
- Reading stays public. `require_authentication` guards writes only.

Password reset ships with the generator, including a mailer. Nothing is wired to a delivery
service and nothing will be — this is a proof of concept, so reset works against the
development mailer and is not expected to send anything real. Likewise no email verification
and no sign-in rate limiting; both are listed under deferred scope below.

### Milestone 3 — Post ownership and CRUD (F-3.x) — **built**

Per-requirement status is in [`REQUIREMENTS.md`](../REQUIREMENTS.md) (F-3.x). What shipped:
`posts.user_id` not null with a foreign key, the free-text `author_name` gone, edit and delete
restricted to the author by scoping, and an "edited" marker on changed posts.

**Two decisions were taken during the milestone** that the plan below did not contain:

- *Posts outlive their author's account, and identities are never reused* — [ADR 0005](adr/0005-posts-outlive-accounts.md).
  A user row is never destroyed, so a released address can never be claimed by someone who
  would then inherit the old account's posts.
- *Authors display as the local part of their email address.* The timeline is public, so
  publishing full addresses invites scraping. Temporary — milestone 4's username replaces it.

The original plan, unchanged:

The slice that makes posts *belong* to someone.

- `posts.user_id`, indexed, not null, `belongs_to :user`.
- The existing `author_name` column is removed. Every post is attributed through the
  association instead.
- Full CRUD: create, read, update, destroy. Edit and delete are restricted to the author.
- Authorization by scoping, per the principle above.
- Composer requires sign-in; signed-out visitors see a prompt instead of the form.

**The existing posts have no user.** The seeded rows are development data, so the migration
backfills them to a single placeholder account rather than inventing a nullable column that
would then need defending forever. Safe here precisely because nothing real is deployed; a
backfill that invents ownership would not be acceptable against production data.

### Milestone 4 — Navigation and profiles (F-4.x) — **built**

Per-requirement status is in [`REQUIREMENTS.md`](../REQUIREMENTS.md) (F-4.x). The plan below
shipped as written. Three things landed alongside it worth naming:

- **A bug the specs could not have named:** on a public (`allow_unauthenticated_access`)
  page, nothing resumed the session before the view read `Current.user` — the feed only
  escaped because its template happens to call `authenticated?` first, and the new profile
  page did not, so it showed every visitor a stranger's page, owner included. Session resume
  is now an unconditional `before_action`; only *requiring* a session stays skippable.
- Cursor pagination moved from `PostsController` into a shared `TimelinePagination` concern,
  since profiles page through posts the same way — and tag pages will next milestone.
- Profile pages got their own query budget spec: 2 queries signed out, 3 signed in, flat
  however many posts render. The extra query over the feed's budget is the username lookup.

The original plan, unchanged:

- A sidebar as the application shell: Feed, Profile, Sign in/out — Search joins it in
  milestone 6. Rendered from a layout partial, not duplicated per page. It replaces the
  milestone 2 masthead.
- `username` added to `User`: unique, case-insensitive, URL-safe — lower-case letters,
  digits and underscores, 3–20 characters. Uniqueness works the way email already does
  (F-2.2): normalised to lower case on write, enforced by a plain unique index, nothing
  adapter-specific.
- **Usernames were chosen at registration and never changed** —
  [ADR 0006](adr/0006-immutable-usernames.md). This is what made `/@username` a stable URL,
  and it kept uniqueness down to one indexed column: were names releasable, a candidate
  would have to be checked against every name ever held, not just the current ones.
  **Since superseded by [ADR 0007](adr/0007-changeable-usernames.md)** — renames are allowed
  from the profile page, and the URL stability that reasoning bought was given up with it.
- Existing users are backfilled from the local part of their email address, deduplicated
  with a numeric suffix. Same licence as milestone 3's backfill: acceptable precisely
  because this is development data — inventing usernames for real accounts would not be.
- `/@username` public profile pages listing that user's posts — the same ordering, cursor
  pagination and post partial as the feed. Reading one never requires an account (F-2.5).
- Edit your own profile — display name (≤ 50 characters) and bio (≤ 160). A singular
  resource acting on the signed-in account: no id in the URL, so a route to anyone else's
  profile settings does not exist, rather than existing and needing a guard (F-4.5).
- The display name appears beside `@username` on posts and profiles, falling back to the
  username when unset. This retires milestone 3's stopgap of showing the email local part.
- Avatars need file storage, so they wait for the media milestone.

### Milestone 5 — Engagement and hashtags (F-5.x)

The milestone that makes the feed interactive. Four independently shippable slices, built in
order — each is a PR or a small series, and each ends with the app working.

#### Slice A — Likes (F-5.6, F-5.7)

The simplest engagement action: a like is a row in a join table, nothing more.

- `Like` model: `user_id` + `post_id`, compound unique index, foreign keys.
- Counter cache `posts.likes_count` so displaying the count never N+1s.
- Like/unlike toggle via Turbo Stream — the button swaps state without a page reload.
- A signed-in user can like any post, including their own. Disallowing self-likes is
  complexity that solves nothing in a proof of concept.
- Signed-out visitors see the count but no toggle.

#### Slice B — Reposts (F-5.8, F-5.9)

Structurally identical to likes — a join table, a counter cache, a toggle.

- `Repost` model: `user_id` + `post_id`, compound unique index, foreign keys.
- Counter cache `posts.reposts_count`.
- Repost/un-repost toggle via Turbo Stream.
- **No timeline fan-out.** On Twitter, a repost puts the original in your followers'
  timelines. There is no follow graph yet, so reposts are a count only — the original post
  stays where it is. Fan-out arrives with the follows milestone.
- No quote posts. Those are a different model (a post that embeds another) and are out of
  scope.

#### Slice C — Replies (F-5.10, F-5.11, F-5.12)

The first change to the `Post` model itself since milestone 3.

- Self-referential `parent_id` on `posts`, nullable foreign key, indexed. A reply is a post
  with a parent — not a separate model. This keeps the body validation, authorship and CRUD
  rules identical for replies and top-level posts.
- Counter cache `posts.replies_count`.
- A **post detail page** at `/posts/:id` showing the post and its direct replies in
  chronological order. The detail page is new — until now, posts only appear on feeds.
- A composer on the detail page for replying, scoped to the parent post.
- The main timeline and profile pages show **top-level posts only** (`WHERE parent_id IS
  NULL`). Replies are visible on the detail page, not scattered through the feed.
- "Replying to @username" context on the detail page above each reply.
- Replies are flat. A reply to a reply is allowed (it sets its own `parent_id`), but there
  is no thread unwinding or nested display — every reply page lists its direct children only.

#### Slice D — Hashtags (F-5.1 through F-5.5)

Unchanged from the original plan. [ADR 0004](adr/0004-hashtags-and-search.md) covers the
join-table decision.

- `#tag` parsed out of the post body on save.
- `Tag` and a `PostTag` join table, rather than `LIKE '%#tag%'` — a join gives an indexed
  lookup, exact matching, and a place to hang tag metadata later. A `LIKE` scan cannot
  distinguish `#rails` from `#railsconf` without more escaping than it is worth.
- Hashtags render as links in post bodies.
- `/tags/:name` lists posts carrying that tag, reusing the existing timeline and cursor
  pagination.
- Tags are normalised to lower case on write so `#Rails` and `#rails` are one tag.

#### Design notes for the milestone

- **Counter caches over live counts.** Each engagement type adds a `_count` column to
  `posts`, maintained by Rails's `counter_cache: true`. This keeps the timeline query flat —
  no subqueries, no N+1. The cost is a write on both the join table and the post row on
  every like/repost/reply, which is fine at this scale.
- **No new query in the timeline.** Likes, reposts and reply counts are columns on `posts`,
  so the timeline query stays the same. Whether the current user has liked or reposted a
  post is one query per page (batch lookup), not per post.
- **Turbo Streams for toggles.** Like and repost are instant toggles that do not navigate.
  Turbo Streams replace the button partial in place, the same pattern as the post composer.

### Milestone 6 — Search (F-6.x)

- A search field in the sidebar, covering post bodies and usernames.
- Results reuse the timeline partial and cursor pagination.

**Search is the first feature where the database actually shows through.** PostgreSQL
full-text search and SQLite FTS5 are different, adapter-specific mechanisms, and N-1.2 says
nothing may depend on adapter-specific behaviour. So this milestone ships a plain
`LIKE`-based search that works identically on both, documented as deliberately basic. Proper
ranked full-text search is a later, separate decision — taken once the app is actually on
PostgreSQL, not before.

### Milestone 5.5 — Feed v2 (F-5.5.x)

The feed graduates from reverse-chronological to ranked, and reposts become visible timeline
entries rather than just a counter. A load-test seed script ships alongside, creating
realistic volume for performance work.

#### Slice A — Reposts in the timeline (F-5.5.1, F-5.5.2, F-5.5.3)

Reposts currently increment a counter but are invisible in the feed. This slice makes them
appear as timeline entries, the way Twitter shows "User reposted" above the original post.

- When a user reposts, the repost appears in the global feed at the time it was created.
- On a user's profile, their reposts are interleaved with their own posts.
- A "Reposted by @username" attribution appears above the original post partial.
- The post itself renders identically — same partial, same engagement buttons.

#### Slice B — Ranked feed algorithm (F-5.5.4, F-5.5.5)

Replace the pure reverse-chronological sort with a score that factors in engagement and
recency. Since the feed is global (no follow graph), the result is the same for everyone
and can be cached.

- Score formula: `(likes_count + reposts_count * 2 + replies_count) / (age_hours + 2)^1.5`.
  Weight is intentionally simple — a more sophisticated algorithm is a later decision.
- Cache the ranked feed since it is universal. Rails low-level cache with a short TTL.
- The timeline still paginates, but the cursor is score-based rather than time-based.

#### Load-test seed data

- A standalone script (`script/seed-load-test`) that creates 1,000 users and 1,000 posts
  with lorem ipsum content, random hashtags, likes, reposts, and replies.
- Works on any database (SQLite or PostgreSQL) — no adapter-specific SQL.
- Runs outside the application process so it cannot overload the running app.
- Documented as the setup step for load testing.

### Milestone 6.5 — Feed caching (F-6.5.x)

The ranked feed loads every post and repost into memory on each request, which is fine at low
volume but visibly slow once the seed data is loaded. Since the feed is universal (same for
every visitor), it can be cached and only rebuilt when engagement changes.

- Cache the scored feed items in `Rails.cache` with a short TTL (e.g. 5 minutes) as a
  safety net.
- Invalidate the cache when engagement changes — `after_create` / `after_destroy` callbacks
  on `Like`, `Repost`, and `Post` bust the cache so the next request rebuilds it.
- Warm the cache on boot via a Rails initializer, so the first request after a deploy or
  restart is served from cache rather than hitting the full query.
- No adapter-specific SQL — the scoring still happens in Ruby, just less often.

### Milestone 7 — Images (F-7.x) — **built**

Per-requirement status is in [`REQUIREMENTS.md`](../REQUIREMENTS.md) (F-7.x). What shipped:

- Active Storage enabled with `image_processing` gem and libvips for server-side processing.
- **Profile avatars (F-7.1):** users upload PNG, JPEG, WebP or GIF. Served as WebP variants
  at 48px (thumbnail, beside posts) and 128px (display, on profile). A default silhouette
  image (`default-avatar.svg`) renders when no avatar is set.
- **Post images (F-7.2):** up to 4 images per post via `has_many_attached :images`. Multi-file
  upload in the composer with content type validation.
- **Processing (F-7.3):** all images resized to fit within 600×600 and converted to WebP.
- **EXIF stripping (F-7.4):** `saver: { strip: true }` on every variant removes metadata.
- **Async loading (F-7.5):** images are Active Storage attachments referenced by URL, not
  inline binary. `loading="lazy"` on `<img>` tags defers browser fetch until the image
  scrolls into view.
- Images stored locally on disk for the proof of concept; cloud storage (S3) is an
  infrastructure milestone concern.

**Refined after the milestone merged**, in follow-up fix PRs:

- Feed images render in a bounded, cropped collage grid (one image capped at 510px keeping
  its aspect ratio; two side by side; three and four as a two-column collage with
  `object-fit: cover`), so a post's height no longer depends on the shape of its photos.
- The composer's raw file input became a camera-icon button with client-side thumbnail
  previews (a Stimulus controller).
- The letter-tile avatar fallback became the default silhouette image, and the post partial
  moved to a two-column layout — avatar left, with the name row, body, images and actions
  aligned in a content column.
- **The production image shipped without libvips** through v0.8.3 — the app booted and served
  while every image variant request failed. The library is now installed in the runtime
  image, and the smoke test uploads an image and fetches its processed variant, so CI's
  container job fails on a missing image library instead of releasing it.

### Milestone 8 — Stress and telemetry (F-8.x) — **built; 100k scale outstanding**

The first milestone after the feature block, and the first whose deliverable was
*measurement* rather than behaviour: make the app observable, load it with realistically
shaped data, stress the ranked feed, and write down what actually happens. All three
slices are merged; the numbers and their caveats live in
[`docs/stress-testing.md`](stress-testing.md).

**Why it existed.** The ranked feed's cost model was known by reading code, not by
measurement. `RankedFeed#compute_feed` loads **every top-level post and every repost into
memory** on each cache miss — with users, avatars and image blobs eager-loaded — scores
and sorts them in Ruby, and caches the whole array under a single key for five minutes.
Every like, repost, reply and new post busts that key. At a 1,000-post seed all of this
was invisible. The stress run existed to find at what scale it stops being invisible,
whether engagement churn turns the cache into a rebuild storm, what a page costs cold
versus warm, and how profile pages behave for accounts three orders of magnitude apart
in size — each is answered under "What the measurement found" below.

#### Slice A — Seed profiles (F-8.1) — shipped

`script/seed-load-test` generates *shaped* data at configurable scale: account shapes
mixed per run rather than uniform (lurkers with nothing through mega-accounts with
thousands of posts), engagement skewed into a small viral head and a long barely-engaged
tail, and scale as an argument so runs are comparable over time. The distribution lives
in `lib/load_test/plan.rb` and is specced in `spec/lib/load_test/plan_spec.rb`; seed
timings are recorded in [`docs/stress-testing.md`](stress-testing.md).

#### Slice B — Telemetry via OpenTelemetry (F-8.2) — shipped

Decided in [ADR 0009](adr/0009-opentelemetry.md): the app is instrumented with
**OpenTelemetry** — Rails and Active Record auto-instrumentation for the request-level
signals (duration, DB time, query counts), plus custom instrumentation in `RankedFeed`
for the feed signals (a rebuild span carrying item count; cache hit or miss on every feed
request). The exporter is configuration: console or a local OTLP endpoint during stress
runs, the infrastructure track's collector once the app runs on the cluster — and unset
means off, with no SDK loaded at all. Instrumented once, exported anywhere — that is the
reason it beat zero-dependency log lines, and the cost is recorded in the ADR.

#### Slice C — Stress scenarios and findings (F-8.3, F-8.4) — shipped at 10k

Decided in [ADR 0008](adr/0008-k6-load-generation.md): **k6** drives the load, so
app-side numbers and the infrastructure track's later cluster-side numbers (I-1g) are
measured by the same tool and comparable without caveats. Four staggered scenarios — the
feed against a warm cache, the same reads while a writer busts the cache, mega-account
profile pages, search under volume — live in `web/script/stress/` and are driven by
`script/stress-test`: locally, streamed to Grafana Cloud k6, or executed from the cloud
through a tunnel. Measured at the 10k seed on two machines; **the 100k scale is
outstanding** (F-8.3 is Partial — that seed run takes about an hour). Findings are in
[`docs/stress-testing.md`](stress-testing.md) as p50/p95/max per scenario.
**Milestone 8 measured and fixed nothing** — improvements are separate follow-up PRs.

**What the measurement found.** The detail and its caveats are in
[`docs/stress-testing.md`](stress-testing.md); the short version:

- A warm feed page is a ~2-second request, and ~77% of it is deserializing the whole
  4.8 MB, 43,058-item cached array to serve 20 posts. At five concurrent readers the
  p95 crosses the 2-second budget even on the faster machine (2.31 s).
- Concurrency queues rather than degrades: the deserialization is CPU-bound and holds
  its Puma thread for the duration, so readers stack behind each other.
- ~~Invalidation is not the problem~~ — **corrected in milestone 8.5 slice D**: the
  churn writer never landed a single write (three compounding harness defects, recorded
  in [`docs/stress-testing.md`](stress-testing.md)), so churn ≈ warm compared a warm
  cache with itself. The per-request deserialization cost stands on the telemetry's
  direct evidence; what invalidation really adds is remeasured in slice G.
- Profile and search stay one to two orders of magnitude faster under identical
  concurrency; both scope and paginate in SQL.

**What follows** is planned as milestone 8.5 below. The overdrive ramp grew into a
proper load-testing harness once the slice C suite's weaknesses were listed honestly;
the 100k measurement and the feed improvement follow it, in that order, so the
before/after comes from the better instruments.

**The boundary with the infrastructure repository.** This milestone is app logic under
data volume, measured against a locally running app — it lives here because the seed
shapes, the telemetry and the feed behaviour are application code. Sustained HTTP load,
latency injection and cluster behaviour belong to I-1g in
[JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra), which consumes
this milestone's seed profiles and telemetry when the app runs on the local cluster.

### Milestone 8.5 — Load-testing harness v2 (F-8.5.x) — **planned**

Milestone 8 proved the pipeline and found the feed's cost, but its harness has known
weaknesses, and fixing the feed against a flawed harness would leave the before/after in
doubt. This milestone rebuilds the harness first; the feed improvement lands after it,
measured properly. Grafana Cloud is the reading surface throughout — k6 results and
server traces in one place.

**What is wrong with the slice C suite**, in the order it misleads:

- **Closed model.** `constant-vus` with think-time couples arrival rate to response
  time: the slower the app gets, the less load the test sends. Real arrivals do not
  slow down because the server did — so the recorded p95s are optimistic. Open-model
  executors (`constant-arrival-rate`, `ramping-arrival-rate`) fix this.
- **Latency only.** Five fixed VUs answers "how slow at light load", never "how much
  can it take", "where does it break" or "does it recover".
- **Unrealistic mix.** Endpoints tested in isolation, sequentially. Real traffic is
  D-1's 90-9-1 concurrently: readers dominating, engagers behind them, creators rare.
- **Thin coverage.** Feed page 1 only — cursor pagination has never been load-tested;
  no post detail page; one cache-friendly search term; the only write is like/unlike.
- **No error-rate thresholds.** Content checks exist but `http_req_failed` is not
  gated, so a run that serves errors can still end green.
- **Dev-mode target.** Code reloading, no eager loading, three threads. Fine for
  comparing runs against each other; wrong for capacity claims.

#### Slice D — the profile suite (F-8.5.1–3) — shipped

`web/script/stress/` restructured into a shared journey library (sign-in and CSRF,
checks) and four profiles, each runnable alone via `script/stress-test <profile>` and
streamable to Grafana Cloud. Building the smoke profile immediately paid for the whole
slice: its write-assertions exposed that the milestone 8 churn writer had never landed a
single like, which invalidated the "invalidation is not the problem" finding — the
correction is recorded above and in
[`docs/stress-testing.md`](stress-testing.md).

| Profile | Executor | Answers | Runtime |
| --- | --- | --- | --- |
| `smoke` | 1–2 VUs, a few iterations | does every journey work at all | ~1 min |
| `load` | constant-arrival-rate, 90-9-1 journey mix | behaviour at normal traffic | 5–10 min |
| `breakpoint` | ramping-arrival-rate until SLOs breach | the knee, and the failure mode | ~5 min |
| `spike` | baseline → ~8× for 90 s → back | survival and recovery of a viral burst | ~4 min |

Journeys, not endpoints: a reader pages the feed on its cursor and opens a post; an
engager also likes and replies; a creator signs in and posts. Every profile carries
per-journey trends, content checks and error-rate thresholds. `scenarios.js` stays
untouched so the recorded milestone 8 numbers keep their lineage; harness v2 numbers
start a new table.

#### Slice E — a production-shape target (F-8.5.4) — shipped

`script/stress-server` builds the `web/Dockerfile` image — the exact artifact the
cluster will pull — and runs it locally with a seeded named volume; `script/stress-test`
gained a `RAILS_RUNNER` override so fixture discovery reads the container's database.
One finding came free: production's `Rails.cache` is a `FileStore` (development uses
`:memory_store`), so every ranked-feed cache hit there reads the payload from disk
before deserializing — the dev-mode numbers understate the feed's cost. The dev server
stays for quick iteration; every recorded run names its target, and deployment numbers
remain I-1g's, in the infrastructure repository.

#### Slice F — Grafana Cloud as the reading surface (F-8.5.5) — shipped

k6 result streaming works since #56. Rails traces to the same stack's Tempo are
documented in [`docs/stress-testing.md`](stress-testing.md) — pure configuration, with
run labels and time ranges as the correlation, and a TraceQL query as the starting
point. The OTLP path is verified end-to-end against a local sink; the final Grafana
Cloud round-trip is one command run by whoever holds the stack's credentials.
`script/stress-server` passes the `OTEL_*` variables into the container so the
production-shape target traces to the same place. k6-to-Tempo trace propagation (k6's
tracing module) remains an option not built on while the module is experimental.

#### Slice G — the measurements, then the fix — baseline taken

The 10k baseline is measured and recorded in
[`docs/stress-testing.md`](stress-testing.md), and it is worse than the closed-model
suite ever showed: at 54 reader journeys a minute the app serves every request
successfully at **p95 13.75 s**, sustains **3.58 requests/second**, and the feed's knee
sits **under 3 requests/second**. Under sustained load it queues rather than failing —
but under a 480/minute burst it stopped answering altogether, losing **31.7% of
requests** to sixty-second timeouts before recovering on its own once the burst passed.

**The feed improvement has shipped** (N-6.8): the ranked *order* is cached as
identifiers and a request loads only the page it displays. Measured before and after on
one machine, at the same seed, with the same profiles — a page 763 ms → 15.8 ms, the
breakpoint ramp from aborting at 62 seconds to completing the full ramp to 600
requests/minute at p95 142 ms, and the load profile from losing 47% of its requests to
losing none while throughput went 1.25 → 4.41 requests/second.

Outstanding: the 100k seed run (closing F-8.3), and the profiles against the
production-shape target. And one new target the fix exposed by no longer hiding it —
the remaining latency tail is a **cache stampede**: writes bust the ordering every few
seconds, a rebuild is 643 ms, and every reader arriving during one recomputes it. That
is the question milestone 8 asked and could not answer, because its churn writer never
wrote.

### Explicitly not in this block

Follows, notifications, moderation and rate limiting. None are currently planned as app
milestones — they can be added if the scope expands.
