# Stress testing

Milestone 8. What we measure, how to reproduce it, and what the numbers say.

Findings are recorded with the scale that produced them. Any improvement that follows
cites the number it moves — see [`roadmap.md`](roadmap.md).

## Seeding shaped data

`script/seed-load-test` builds a timeline with a realistic *shape* rather than uniform
random data (F-8.1). The distribution lives in `lib/load_test/plan.rb` and is specced in
`spec/lib/load_test/plan_spec.rb`; the script only performs the writes.

```bash
cd web
bin/rails db:reset                                  # start from empty
bin/rails runner script/seed-load-test              # 10,000 posts (default)
bin/rails runner script/seed-load-test 1000         # quick run
bin/rails runner script/seed-load-test 100000       # the big one
bin/rails runner script/seed-load-test 10000 --seed=7   # a different draw
```

The same `--seed` reproduces the same database, so two runs are comparable. It seeds a
shape rather than topping up to a target, so **reset before re-seeding** — running it
twice appends a second population.

**What "shaped" means.** Accounts are mixed: 60% lurkers who never post, 30% typical
accounts, 9% heavy, 1% mega-accounts, with at least one of every shape at any scale.
Engagement is skewed rather than spread: 55% of posts get nothing at all, and the top 1%
carry roughly a third of it. Both matter — uniform data hides the behaviour this
milestone is looking for.

Measured on the development machine, SQLite, WAL:

| Scale | Rows created | Seed time |
| --- | --- | --- |
| 1,000 posts | 86 users, 1,008 posts + 1,626 replies, 5,447 likes, 3,035 reposts | ~43s |
| 10,000 posts | 836 users, 10,008 posts + ~16k replies, 110,363 likes, 33,050 reposts | ~8m15s |

Likes and reposts are written with `insert_all` and their counter caches reconciled in one
statement per column afterwards; inserting them as individual records measured ~5ms each
even inside a transaction, which put a 100,000-post seed into the hours. Replies stay on
`Post.create!` because they are posts — they run the body validation and hashtag parsing
the app really does. Counter caches were verified exact against `COUNT(*)` for all 2,634
posts of a 1,000-post run.

## Telemetry

The app is instrumented with OpenTelemetry ([ADR 0009](adr/0009-opentelemetry.md), F-8.2).
Rails auto-instrumentation supplies the request-level signals — request duration, database
time, query counts, view rendering — and `RankedFeed` carries custom spans for what this
milestone is actually measuring:

| Span | Attributes | What it tells you |
| --- | --- | --- |
| `ranked_feed.read` | `cache_hit`, `item_count` | What a request waited for, and whether it paid for a rebuild |
| `ranked_feed.rebuild` | `item_count` | How long a full recompute took, and how much it produced |
| `ranked_feed.bust` | — | Cache invalidation, one per like, repost, reply or post |

The exporter is configuration, not code, so the same instrumentation serves a local run and
a collector later:

```bash
# print spans to stdout
OTEL_TRACES_EXPORTER=console bin/rails server

# send them to a collector
OTEL_TRACES_EXPORTER=otlp OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 bin/rails server
```

**Unset means off, and off means genuinely off** — no SDK, no instrumentation, no spans
created. This is worth stating because the SDK's own default for `OTEL_TRACES_EXPORTER` is
`otlp`: configured unconditionally, every process tries to POST spans to `localhost:4318`,
logs an export failure per batch, and — the expensive part — wraps every Active Record call
in a span whether or not anything is listening. A seed run is thousands of writes and paid
that cost on all of them. The initializer therefore only configures the SDK when an
exporter is asked for, or in test, where the specs attach their own in-memory exporter and
need a real tracer provider to attach it to. That is how the feed signals are asserted in
`spec/services/ranked_feed_telemetry_spec.rb` rather than eyeballed in a log.

## Baseline: the ranked feed at 10,000 posts

Taken with slice A's seed, before any telemetry or k6 work, as the reason the rest of the
milestone exists. Development machine, SQLite, `RankedFeed` unchanged.

| Measurement | Result |
| --- | --- |
| Feed **cold** (cache busted, full rebuild) | **5,965 ms** |
| Feed **warm** (cache hit) | **1,417 ms** |
| SQL queries during a cold rebuild | 2 |
| Items held in the cache | 43,058 |
| Serialized cache payload | 4.8 MB |
| Mega-account profile page (873 posts) | 63 ms |

**Reading these.** Two queries means the problem is not N+1 — the eager-loading is doing
its job. The cost is volume: `RankedFeed#compute_feed` loads every top-level post *and*
every repost, with users, avatars and image blobs attached, scores each in Ruby and sorts
the lot, to serve 20 items.

The warm number is the finding worth stopping on. **A cache hit costs 1.4 seconds** —
because the cached value is a 4.8 MB array of 43,058 objects that Rails has to
deserialize in full on every request, only to drop all but 20 of them. Caching made the
feed faster than recomputing it, and left it far from fast.

And the cache is busted by *every* like, repost, reply and new post. At this seed's
engagement volume, a feed under write traffic spends much of its time in the 6-second
rebuild path rather than the 1.4-second one — which is what slice C's churn scenario is
built to measure.

By contrast the mega-account profile page at 873 posts is 63 ms: `ProfileFeed` scopes to
one user and paginates in SQL, so it never had this shape of problem.

### Over HTTP, with telemetry

The numbers above come from calling `RankedFeed` directly. With slice B's instrumentation
the same seed can be measured the way a browser experiences it — `OTEL_TRACES_EXPORTER=console`,
one `GET /` against a warm cache:

| Span | Duration |
| --- | --- |
| `GET /` — what the browser waits for | **2,105 ms** |
| ↳ `ranked_feed.read`, `cache_hit=true`, 43,058 items | **1,627 ms** |
| `ranked_feed.rebuild` at boot (`RankedFeed.warm`) | 7,275 ms |
| `render_partial.action_view` spans in one request | 107 |

Two things this adds to the direct-call numbers. **A warm feed page is a two-second
request**, and 77% of it is the cached-feed read — the same 1.4-second deserialization
seen directly, now confirmed as the dominant cost of a real request rather than an
artifact of benchmarking. And boot is not free either: warming the cache in an initializer
costs seven seconds before the process serves anything.

The 107 partial renders for 20 posts are not a problem at this scale — roughly five
partials per post is what the markup asks for — but they are worth knowing about before
anyone reads the remaining 400 ms as mysterious.

## Under concurrent load: the k6 scenarios

Slice C (F-8.3), run with `script/stress-test` against the 10,000-post seed. Four
scenarios, staggered rather than concurrent, because the churn scenario deliberately busts
the cache and the warm scenario must not have that happening to it.

**Read the caveat first.** These come from a development-mode server with
`RAILS_MAX_THREADS=3` and a single Puma process, on the development machine. Development
mode carries code reloading and no eager loading, and three threads is not a production
shape. The absolute numbers describe this setup, not a deployment; what they are good for
is comparing scenarios against each other and finding the shape of the problem. Numbers
that describe a deployment come from I-1g in the infrastructure repository, on the cluster.

Run on two machines against the same 10,000-post seed, which is the more useful thing to
have: one is a container in a sandbox, the other an Apple Silicon laptop roughly four times
quicker. The absolute numbers differ by that factor; the *ratios* do not, and the ratios
are the finding.

**Machine A — sandbox container**, 317 checks, 100% passing:

| Scenario | VUs | avg | p50 | p95 | max |
| --- | --- | --- | --- | --- | --- |
| `feed_warm` — steady reads, warm cache | 5 | 7.10 s | 7.04 s | 9.72 s | 9.86 s |
| `feed_churn` — same reads, writer liking throughout | 5 + 1 | 7.01 s | 7.19 s | 10.06 s | 11.17 s |
| `profile` — mega-account | 5 | 404 ms | 410 ms | 638 ms | 867 ms |
| `search` — `?q=the` against the volume | 5 | 133 ms | 97 ms | 397 ms | 794 ms |

**Machine B — Apple Silicon laptop**, 514 checks, 100% passing:

| Scenario | VUs | avg | p50 | p95 | max |
| --- | --- | --- | --- | --- | --- |
| `feed_warm` | 5 | 1.71 s | 2.14 s | 2.31 s | 2.38 s |
| `feed_churn` | 5 + 1 | 1.53 s | 1.50 s | 2.30 s | 2.98 s |
| `profile` — mega-account, 759 posts | 5 | 70 ms | 68 ms | 131 ms | 188 ms |
| `search` | 5 | 31 ms | 24 ms | 70 ms | 127 ms |

Nothing errored on either machine — 831 checks between them, all passing. Everything was
merely slow.

**What survives the change of hardware.** The feed costs 24× a profile page on the fast
machine and 18× on the slow one; against search it is 55× and 53×. Four times the CPU buys
four times less waiting and changes nothing about the shape. And the feed still misses a
two-second budget at p95 on the faster machine — with five users, on a proof of concept,
against ten thousand posts.

**Two findings, and the second overturns an assumption.**

*Concurrency multiplies the feed's cost rather than absorbing it.* On machine A a single
request measured 2.1 s and five concurrent readers saw 7 s. The per-request work —
deserializing a 4.8 MB cached array — is CPU-bound and holds its thread for the duration,
so with three threads the sixth request queues behind two full deserializations before it
starts. The feed does not degrade gracefully under concurrency; it queues.

*Invalidation is not the problem.* The churn scenario was built expecting the write traffic
to be the expensive part, on the reasoning that every like busts the cache and forces a
rebuild. On both machines it measured **no worse than the warm scenario** — 7.01 s against
7.10 s on A, 1.53 s against 1.71 s on B, churn marginally ahead each time and well inside
the noise. Two independent runs agreeing is what makes this worth acting on: the rebuild
frequency barely matters, because the dominant cost is paid on *every* request whether it
hits or misses. That points any improvement work away from "bust the cache less often" and
towards "stop deserializing the whole feed to serve twenty items".

Profile and search stay fast under the same concurrency, which is what makes the
comparison worth having: both scope and paginate in SQL, and neither holds a thread doing
Ruby work proportional to the size of the database.

**Not fixed here.** Milestone 8 measures. The improvements these numbers argue for — a
per-page cache rather than one whole-feed key, or scoring in SQL — land afterwards as
their own pull requests, each citing the number above that it moves.

