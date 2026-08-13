# Requirements

What the application must do, and the constraints it must do it under. Scope and sequencing
live in [`docs/roadmap.md`](docs/roadmap.md); this file is the checklist that says whether a
milestone is actually finished. Decisions and their costs are in
[`docs/adr/`](docs/adr/); questions not yet decided are in
[`docs/open-questions.md`](docs/open-questions.md).

Each requirement has an ID so specs, commits and issues can point at it.

Status: **Met** — implemented and covered by tests. **Partial** — implemented but
incomplete. **Planned** — agreed, not built. **Open** — not yet decided. **Deferred** —
knowingly not done, because this is a proof of concept and nothing is deployed.

A **Deferred** row is not a to-do. It is a gap recorded so that nobody mistakes the app for
production-ready, and so the work is visible if it ever is deployed.

---

## 1. Functional requirements

### 1.1 Feed (milestone 1)

| ID | Requirement | Status |
| --- | --- | --- |
| F-1.1 | A visitor can write a post from a composer on the feed page | Met |
| F-1.2 | A post has a body of 1–280 characters | Met |
| F-1.3 | A post carries an author name of at most 50 characters, defaulting to `anonymous` when left blank | Met — superseded by F-3.1 in milestone 3, which replaces the free-text name with a real account |
| F-1.4 | The feed lists posts newest first | Met |
| F-1.5 | Ordering is stable and total — posts sharing a timestamp never reorder between requests | Met |
| F-1.6 | A new post appears at the top of the timeline without a full page reload | Met |
| F-1.7 | The feed loads at most 20 posts per page | Met |
| F-1.8 | Older posts are reachable through a cursor, and no post is repeated or skipped as new posts arrive | Met |
| F-1.9 | An invalid post re-renders the composer with its errors and leaves the timeline intact | Met |
| F-1.10 | An empty timeline shows an empty state rather than a blank page | Met |

### 1.2 Authentication (milestone 2)

| ID | Requirement | Status |
| --- | --- | --- |
| F-2.1 | A visitor can register with an email address and password | Met |
| F-2.2 | Email addresses are unique, case-insensitively | Met — addresses are normalised to lower case on write, so the plain unique index enforces it without an adapter-specific functional index |
| F-2.3 | A registered user can sign in and sign out | Met |
| F-2.4 | Signing out revokes the session server-side, not only in the browser | Met — `terminate_session` destroys the `Session` row |
| F-2.5 | Reading the feed, profiles and tag pages never requires an account | Met for the feed and profiles; tag pages arrive with milestone 5 |
| F-2.6 | Creating, editing and deleting require a signed-in user | Met for create; edit and delete arrive with milestone 3 |
| F-2.7 | A user can reset a forgotten password | Met — against the development mailer only; see N-5.1 |

### 1.3 Post ownership and CRUD (milestone 3)

| ID | Requirement | Status |
| --- | --- | --- |
| F-3.1 | Every post belongs to a user account | Met — `posts.user_id`, not null, indexed, with a foreign key |
| F-3.2 | A user can edit their own post | Met |
| F-3.3 | A user can delete their own post | Met |
| F-3.4 | A user cannot edit or delete anyone else's post | Met — another account's post is not found, so it raises rather than being refused after the fact |
| F-3.5 | Authorisation is enforced by scoping through the association, not by a check after loading | Met — `Current.user.posts.find(params[:id])` |
| F-3.6 | A signed-out visitor sees a prompt to sign in where the composer would be | Met — arrived with milestone 2, since guarding `create` without it would have shown a form that only bounced the visitor to sign in |

### 1.4 Navigation and profiles (milestone 4)

| ID | Requirement | Status |
| --- | --- | --- |
| F-4.1 | A sidebar provides navigation between the feed, the user's profile, and signing in or out | Met — a layout partial on every page; folds into a top bar on narrow screens |
| F-4.2 | Each user has a unique, case-insensitive, URL-safe username | Met — stored lower-cased behind a plain unique index, the same mechanism as F-2.2 |
| F-4.3 | A public profile page lists that user's posts, newest first | Met — `/@username`, same ordering and cursor pagination as the feed |
| F-4.4 | A user can edit their own display name and bio | Met |
| F-4.5 | A user cannot edit anyone else's profile | Met — the edit routes carry no id and act on the session's user, so a route to anyone else's profile does not exist |
| F-4.6 | A username is unique and changeable — a name already held is refused with "has already been taken" | Met — editable on the profile page; one indexed exact-match lookup, with the unique index as the backstop. [ADR 0007](docs/adr/0007-changeable-usernames.md) supersedes [0006](docs/adr/0006-immutable-usernames.md) |
| F-4.7 | The logo appears on every page and returns to the feed | Met — the sidebar brand is the logo, linking to `/` |
| F-4.8 | The sidebar collapses to an icon rail, and the choice is remembered | Met — a Stimulus toggle writing to `localStorage`; the class is applied in `<head>` so the rail does not flash open on load. Desktop only — the narrow-screen top bar is already the compact form |
| F-4.9 | The browser tab carries the app's mark, not the generator's placeholder | Met — the logo SVG is the favicon; `public/icon.png` is rasterized from it for `apple-touch-icon` |

### 1.5 Engagement and hashtags (milestone 5)

| ID | Requirement | Status |
| --- | --- | --- |
| F-5.1 | Hashtags are parsed out of a post body when it is saved | Met — `after_save :sync_tags` callback parses `#(\w+)` from body |
| F-5.2 | Tags are stored in their own table with a join, not matched with `LIKE` | Met — `Tag` + `PostTag` join table per ADR 0004 |
| F-5.3 | Tags are normalised to lower case, so `#Rails` and `#rails` are one tag | Met — `normalizes :name` on Tag, parsing downcases before find_or_create |
| F-5.4 | Hashtags render as links in a post body | Met — `render_body_with_hashtags` helper links to `/tags/:name` |
| F-5.5 | A tag page lists every post carrying that tag, with the same ordering and pagination as the feed | Met — `TagsController#show` with timeline pagination |
| F-5.6 | A signed-in user can like and unlike a post | Met — `Like` join table with counter cache, Turbo Stream toggle |
| F-5.7 | A post displays its like count | Met — `posts.likes_count` counter cache, batch lookup for current-user state |
| F-5.8 | A signed-in user can repost and un-repost a post | Met — `Repost` join table with counter cache, Turbo Stream toggle |
| F-5.9 | A post displays its repost count | Met — `posts.reposts_count` counter cache, batch lookup for current-user state |
| F-5.10 | A signed-in user can reply to a post | Met — replies are posts with a `parent_id`, created via `RepliesController` |
| F-5.11 | A post detail page lists the post and its direct replies | Met — `GET /posts/:id` shows parent + chronological replies with "replying to @username" context |
| F-5.12 | A post displays its reply count | Met — `posts.replies_count` counter cache, displayed as a link to the detail page |

### 1.6 Search (milestone 6)

| ID | Requirement | Status |
| --- | --- | --- |
| F-6.1 | A search field in the sidebar finds posts by body text | Met — `Post.search` LIKE scope, sidebar link to `/search` |
| F-6.2 | Search also finds users by username | Met — `User.search` LIKE scope, user results shown above posts |
| F-6.3 | Search behaves identically on SQLite and PostgreSQL | Met — plain `LIKE` with `sanitize_sql_like`, no adapter-specific SQL |
| F-6.4 | Results reuse the timeline rendering and cursor pagination | Met — reuses `_post` partial, `TimelinePagination` concern, and `_pagination` partial |

### 1.6b Feed v2 (milestone 5.5)

| ID | Requirement | Status |
| --- | --- | --- |
| F-5.5.1 | A repost appears as a timeline entry in the global feed, attributed to the reposter | Met — `RankedFeed` merges posts and reposts into `FeedItem` entries |
| F-5.5.2 | A user's profile page interleaves their reposts with their own posts | Met — `ProfileFeed` merges user's posts and reposts, sorted by time |
| F-5.5.3 | A reposted entry shows "Reposted by @username" above the original post | Met — `_feed_item.html.erb` renders attribution above the post partial |
| F-5.5.4 | The feed is ranked by a score combining engagement (likes, reposts, replies) and recency | Met — `RankedFeed` scores `(engagement + 1) / (age_hours + 2)^1.5` |
| F-5.5.5 | The ranked feed is cached since it is universal (same for every visitor) | Met — `Rails.cache` with engagement invalidation and warm-on-boot (milestone 6.5) |
| F-5.5.6 | A load-test seed script creates 1,000 users and 1,000 posts with realistic engagement data | Met — `script/seed-load-test` via `bin/rails runner` |
| F-5.5.7 | The seed script works on any supported database and runs outside the app process | Met — no adapter-specific SQL, runs via `bin/rails runner` |

### 1.6c Feed caching (milestone 6.5)

| ID | Requirement | Status |
| --- | --- | --- |
| F-6.5.1 | The ranked feed is cached in `Rails.cache` so repeated requests do not recompute it | Met — `Rails.cache.fetch` with 5-minute TTL in `RankedFeed` |
| F-6.5.2 | The cache is invalidated when engagement changes (like, repost, reply, new post) | Met — `after_commit` callbacks on `Post`, `Like`, and `Repost` call `RankedFeed.bust_cache` |
| F-6.5.3 | The cache is warmed on app boot so the first request is fast | Met — `config/initializers/warm_ranked_feed.rb` calls `RankedFeed.warm` |

### 1.7 Images (milestone 7)

| ID | Requirement | Status |
| --- | --- | --- |
| F-7.1 | A user can upload an avatar image on their profile | **Met** |
| F-7.2 | A post can carry one or more images | **Met** |
| F-7.3 | Uploaded images are processed (resized, converted to a web-friendly format) for fast loading | **Met** — resized to fit 600×600 and converted to WebP by libvips. The production image lacked libvips until v0.8.4; the smoke test now exercises a variant so the gap cannot reopen silently |
| F-7.4 | Image metadata (EXIF, etc.) is stripped on upload | **Met** |
| F-7.5 | Posts reference images via metadata, not inline binary — images load asynchronously | **Met** |

### 1.8 Stress and telemetry (milestone 8)

| ID | Requirement | Status |
| --- | --- | --- |
| F-8.1 | The load-test seed generates shaped data at configurable scale — mixed account sizes from lurker to mega-account, skewed engagement — on any supported database | **Met** — `lib/load_test/plan.rb`, specced in `spec/lib/load_test/plan_spec.rb`; usage and timings in [`docs/stress-testing.md`](docs/stress-testing.md) |
| F-8.2 | The app is instrumented with OpenTelemetry: request duration, DB time and query counts from auto-instrumentation, plus feed rebuild duration, item count and cache hit/miss from custom spans — exporter chosen by configuration ([ADR 0009](docs/adr/0009-opentelemetry.md)) | **Met** — `config/initializers/opentelemetry.rb` and spans in `RankedFeed`, asserted in `spec/services/ranked_feed_telemetry_spec.rb` |
| F-8.3 | Repeatable k6 scenarios exercise the feed cold, warm and under engagement churn — plus mega-account profiles and search — at the 10k and 100k seed scales ([ADR 0008](docs/adr/0008-k6-load-generation.md)) | **Partial** — measured at 10k, not yet at 100k. The slice C scenarios are superseded by the milestone 8.5 profiles, whose 10k baseline is recorded in [`docs/stress-testing.md`](docs/stress-testing.md) |
| F-8.4 | Findings are written down with numbers, and every improvement that follows traces to a measured problem | **Met** — [`docs/stress-testing.md`](docs/stress-testing.md) records seed timings, the telemetry baseline and the k6 results, with their caveats |

### 1.8b Load-testing harness v2 (milestone 8.5)

| ID | Requirement | Status |
| --- | --- | --- |
| F-8.5.1 | The stress suite is organised as independently runnable profiles — smoke, load, breakpoint, spike — each streamable to Grafana Cloud k6 | **Met** — `script/stress-test <profile>`, profiles in `script/stress/`, journeys shared via `script/stress/lib.js` |
| F-8.5.2 | The load profile drives an open-model, mixed workload: request arrival independent of response time, journeys mixed 90-9-1 (readers, engagers, creators) across feed pages, post detail, profiles, search and writes | **Met** — `constant-arrival-rate` scenarios at per-minute rates; the reader pages `?page=1`, previously never load-tested |
| F-8.5.3 | Every profile gates on error rate as well as latency, so a run that serves errors cannot end green | **Met** — `http_req_failed` thresholds on all four profiles, content-marker checks on every request, and write journeys assert the write landed |
| F-8.5.4 | Capacity numbers (breakpoint, spike) are taken against a production-shape target — the container image with eager loading and tuned Puma — and every recorded run names its target | **Met** — `script/stress-server` (build, seed, serve); discovery via `RAILS_RUNNER`; production posture validated end-to-end with the smoke profile |
| F-8.5.5 | Rails traces export to Grafana Cloud Tempo by configuration alone, correlated with k6 runs by label and time range, documented in [`docs/stress-testing.md`](docs/stress-testing.md) | **Partial** — configuration and correlation documented; OTLP export verified against a local sink; the Tempo round-trip needs the stack's credentials, so it is a user-run command |

### 1.8c Absence handled deliberately (milestone 8.6)

| ID | Requirement | Status |
| --- | --- | --- |
| F-8.6.1 | Invalidating the ranked feed leaves the previous ordering readable, and only one request rebuilds it at a time — everyone else is served the previous ordering rather than recomputing it | **Met** — `RankedFeed` marks stale and claims a rebuild lock, specced in `ranked_feed_stampede_spec.rb`. Reader p95 2.52 s → 980 ms, slowest request 8.00 s → 1.84 s ([`docs/stress-testing.md`](docs/stress-testing.md)) |
| F-8.6.2 | A request for a record that does not exist answers 404 with the application's own page, not the generic static one, and does not distinguish "deleted" from "not yours" | **Met** — `ApplicationController#render_not_found`, specced in `spec/requests/not_found_spec.rb` |

### 1.8d The ranking considers a recent window (milestone 8.7)

| ID | Requirement | Status |
| --- | --- | --- |
| F-8.7.1 | Only entries dated inside `RankedFeed::WINDOW` compete for the top of the feed — a post by its creation, a repost by the repost, which is how an old post re-enters the ranking ([ADR 0011](docs/adr/0011-ranked-window.md)) | **Met** — windowed `compute_ordering`, cutoff cached with the entries; specced in `feed_window_spec.rb` and `ranked_feed_window_spec.rb` |
| F-8.7.2 | The feed continues past the window into everything older, newest first — unlimited scroll survives, and the boundary costs one bounded query, never a COUNT | **Met** — archive pages served off the `(created_at, id)` index; query shape asserted in `ranked_feed_page_cost_spec.rb` and `ranked_feed_window_spec.rb` |
| F-8.7.3 | Old posts are removed from nothing else: search, profiles, tag pages and the post's own page are not windowed | **Met** — asserted per surface in `feed_window_spec.rb` |

---

## 1b. Design requirements

| ID | Requirement | Status |
| --- | --- | --- |
| D-1 | Reading is public; only writing requires an account (90-9-1: most visitors are lurkers) | Met — the feed and profiles render signed out; `create`, `update` and `destroy` are guarded |
| D-2 | Posting is reachable from the feed itself, not behind a separate page | Met |
| D-3 | Power-user tooling — bulk management, drafts, scheduling — stays absent until the first two groups are served | Met — by omission |

---

## 2. Non-functional requirements

### 2.1 Data

| ID | Requirement | Status |
| --- | --- | --- |
| N-1.1 | The app runs on SQLite with no external services, so a checkout boots with one command | Met |
| N-1.2 | Switching to PostgreSQL requires no code change — only `DATABASE_URL` and installing the `pg` gem | Met |
| N-1.3 | Every schema change ships as a migration; `db/schema.rb` is never hand-edited | Met |
| N-1.4 | Columns used for timeline ordering are indexed | Met |
| N-1.5 | Production runs on managed PostgreSQL | Planned |

### 2.2 Quality

| ID | Requirement | Status |
| --- | --- | --- |
| N-2.1 | RuboCop passes with `rubocop-rails-omakase`, and CI fails on any offence | Met |
| N-2.2 | Model behaviour is covered by model specs, controller behaviour by request specs | Met |
| N-2.3 | A change that adds behaviour without a test is incomplete | Met |
| N-2.4 | No system/browser specs until the UI justifies the maintenance cost | Met |
| N-2.5 | SonarQube quality gate passes | Open — needs a server and `SONAR_TOKEN` |

### 2.3 Security

| ID | Requirement | Status |
| --- | --- | --- |
| N-3.1 | Brakeman runs on every pull request and fails on any warning | Met |
| N-3.2 | Gem CVEs are detected by bundler-audit on every pull request | Met |
| N-3.3 | Trivy scans the source tree; any fixable HIGH or CRITICAL fails the build | Met |
| N-3.4 | Trivy scans the built image; any fixable HIGH or CRITICAL fails the build | Met |
| N-3.5 | A DAST baseline scan runs against the running container | Partial — runs, but does not yet fail the build |
| N-3.6 | The container runs as a non-root user | Met |
| N-3.7 | The production image contains no development or test dependencies | Met |
| N-3.8 | User-supplied content is escaped on output | Met — ERB escapes by default |
| N-3.9 | Secrets are never committed; Trivy scans for them | Met |
| N-3.10 | The base image is kept current, since inherited CVEs fail the build like any other | Met |
| N-3.11 | SSL is enforced wherever the app is served over TLS — HSTS, https redirect, secure cookies | Deferred — `RAILS_FORCE_SSL` and `RAILS_ASSUME_SSL` default to off so the image runs over plain HTTP. Both must be set to `true` in any deployed environment |

### 2.4 Delivery

| ID | Requirement | Status |
| --- | --- | --- |
| N-4.1 | All work reaches the default branch through a pull request | Met |
| N-4.2 | A pull request merges only once every required check has passed | **Not met — `main` has no required status checks, so GitHub reports every pull request as mergeable immediately and refuses to arm auto-merge. Merges so far have been manual after checking CI by hand. Needs a branch ruleset requiring Lint, Test, SAST and Container.** |
| N-4.2a | A branch must be up to date with `main` before merging | **Not met — nothing re-validates the merge commit now that CI is pull-request-only, so two branches can each pass in isolation and still break once merged.** |
| N-4.3 | Commits follow Conventional Commits, since the version bump is derived from them | Met |
| N-4.4 | The version is derived automatically; no one edits a version by hand | Met |
| N-4.5 | The image builds reproducibly from `web/Dockerfile` | Met |
| N-4.6 | The image is proven to boot and serve traffic before release | Met — CI starts it, polls `/up`, then runs the full HTTP smoke test against it: register, post, upload an image and fetch its processed variant, edit, delete, sign out. The variant fetch was added after v0.8.0–0.8.3 shipped without libvips — the image booted and served while unable to process a single upload, which `/up` alone can never catch |
| N-4.7 | Images are tagged with the version, an immutable commit SHA, and `latest` | Met |
| N-4.8 | Images are published to a container registry on release | Met — GitHub Container Registry |
| N-4.9 | Published images run on both `linux/amd64` and `linux/arm64` | Met |
| N-4.10 | Images are published to Amazon ECR | Planned — written and commented out pending AWS setup |
| N-4.11 | The app is deployed to AWS | Planned |

---

## 2.5 Deferred by proof-of-concept scope

Real answers are needed only if this is ever deployed.

| ID | Requirement | Status |
| --- | --- | --- |
| N-5.1 | Password reset email reaches a real inbox | Deferred — the flow and mailer exist; no delivery service is configured, so reset sends nothing outside development |
| N-5.2 | An email address is verified before the account can post | Deferred — an account can be registered against an address its owner does not control |
| N-5.3 | Sign-in attempts are rate limited | Met — the generator applies `rate_limit to: 10, within: 3.minutes` to sign-in, password reset and registration. It counts through `Rails.cache`, so the limit is per-process and resets on restart; a shared store is needed before it means anything under more than one instance |
| N-5.4 | Sessions expire after a period of inactivity | Deferred |
| N-5.5 | The app is backed up, and restores are tested | Deferred — SQLite in a container volume, no backups |
| N-5.6 | Deleting an account erases the personal data it held | Deferred — ADR 0005 keeps the user row forever so a released identity can never be reclaimed, which means the email address is retained. Squaring erasure with that means storing a fingerprint of the address rather than the address |

---

## 2.6 Latency and degradation

How the app behaves when the network between it and its database is slow. Nothing here is
built; the reasoning and the proposed order are in [`docs/latency.md`](docs/latency.md).

None of this is testable on SQLite, which runs in-process with no wire to slow down, so all of
it depends on the PostgreSQL path — which is itself an untested claim today (N-1.2, ADR 0003).

| ID | Requirement | Status |
| --- | --- | --- |
| N-6.1 | Rendering the feed issues a constant number of queries, regardless of how many posts are on the page | Met — 1 signed out, 4 signed in (session + posts + batch like lookup + batch repost lookup), flat from 1 post to a full page. Profile pages hold the same property at 2 signed out and 5 signed in, the extra query being the username lookup |
| N-6.2 | Query count per request is asserted in specs, so a regression fails the build rather than being noticed as slowness | Met — `feed_query_budget_spec.rb` and `profile_query_budget_spec.rb` |
| N-6.8 | Serving a page of the feed costs work proportional to the page, not to the number of posts in the database | **Met** — `RankedFeed` caches the ranked order as identifiers and loads only the page displayed, asserted in `ranked_feed_page_cost_spec.rb`. Before/after in [`docs/stress-testing.md`](docs/stress-testing.md): a page 763 ms → 15.8 ms, the breakpoint ramp from aborting at 62 s to completing at 600 req/min, the load profile from losing 47% of requests to losing none |
| N-6.3 | The connection pool is larger than the Puma thread count | Open — equal when `RAILS_MAX_THREADS` is set, since both read it |
| N-6.4 | Connection, checkout and statement timeouts are configured and adapter-neutral | Not met — the only timeout set is `timeout: 5000`, which is SQLite's `busy_timeout` and is ignored by PostgreSQL |
| N-6.5 | A readiness endpoint reports unhealthy when the database is unreachable | Not met — `/up` checks only that the app booted, so it returns 200 against a dead database. Deliberately separate from `/up`, which should not restart the app because a dependency is down |
| N-6.6 | Behaviour under injected latency is measured and written down — p50/p95, queries per request, errors | Open — proposed harness is Toxiproxy between the app and PostgreSQL containers |
| N-6.7 | The test suite passes against PostgreSQL, not only SQLite | Not met — no CI job has ever run it |

---

## 3. Out of scope

Explicitly not being built, to keep the current milestone honest:

- The follow graph and any personalised timeline.
- Notifications.
- Account deletion.
- Ranked full-text search. Milestone 6 ships a plain `LIKE` search that works on both
  adapters; anything better is a decision to take once the app is on PostgreSQL.
- Background jobs. Sidekiq and Redis arrive when a milestone needs them.
- Spam controls and moderation. Sign-in rate limiting is an open question, not a commitment.
