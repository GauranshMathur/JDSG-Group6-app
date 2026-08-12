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

## Sending results to Grafana Cloud k6

Two modes, and the difference matters more than the names suggest.

**`K6_MODE=stream` — generate the load here, upload the results.** Almost always the one
you want. The load still comes from this machine against localhost, so the numbers stay
comparable with every local run recorded above; the dashboard is the only thing that
changes. No tunnel involved.

```bash
k6 cloud login --token <token>
K6_MODE=stream script/stress-test

# label the run so it is findable in the dashboard later
RUN_LABEL="10k baseline" K6_MODE=stream script/stress-test
```

The first streamed run (Grafana Cloud test run 8349790 — machine B below, the same
10,000-post seed) behaved as the mode promises: 525 requests, none failed, 509/509 content
checks, aggregate p95 2.21 s, and one of the four thresholds crossed. The aggregate leaves
no other candidate than `scenario_feed_warm`'s p(95) < 2000 ms — the local run below
crosses it at 2.31 s while the other three scenarios sit an order of magnitude inside
their budgets. Streaming changed where the results went and nothing about what they
measured, which is the property that makes the dashboard usable for before/after
comparison when the improvement work lands.

**`K6_MODE=cloud` — generate the load in the cloud.** A different measurement, not a nicer
version of the same one. The app has to be reachable from the internet, which for a
development server means a tunnel:

```bash
k6 cloud login --token <token>
ngrok http 3000                                       # any tunnel will do

# Rails blocks unrecognised Host headers in development, so name the tunnel:
DEV_ALLOWED_HOSTS=<subdomain>.ngrok-free.dev bin/rails server

K6_MODE=cloud script/stress-test https://<subdomain>.ngrok-free.dev
```

`DEV_ALLOWED_HOSTS` is comma-separated and read at boot. It exists because
`ActionDispatch::HostAuthorization` is worth keeping — it is what stops a hostile page in
your browser from pointing its own domain at 127.0.0.1 and talking to your development
server — so the tunnel is named rather than the guard switched off. A leading dot allows a
whole domain (`.ngrok-free.dev`), which survives the subdomain changing between sessions
and is a correspondingly wider opening.

**What a cloud run is and is not good for.** Load generated in a cloud region, crossing the
public internet and a free tunnel to reach a laptop, spends most of its latency budget on
the journey; a free tunnel also rate-limits. It answers "do the scenarios run from
somewhere other than my machine" and "does the app hold up when requests arrive over a real
network". It does not produce a number comparable with the local runs below, and it is not
a deployment measurement — those come from I-1g in the infrastructure repository, where the
load generator and the app sit in the same cluster.

**One thing the tunnel forced, worth keeping regardless.** A free ngrok tunnel answers
anything browser-shaped with an interstitial warning page, served as a 200. The scenarios
originally checked only the status code, so a tunnelled run could have reported four green
scenarios having measured nothing but ngrok. Every request now sends
`ngrok-skip-browser-warning`, and every check asserts a marker only that page contains —
`feed__` for the feed, the username for a profile, `Search` for search. A Rails "Blocked
host" page or a proxy error fails those checks rather than passing as a fast 200.

## Under concurrent load: the k6 scenarios

Slice C (F-8.3), run with `script/stress-test` against the 10,000-post seed. Four
scenarios, staggered rather than concurrent, because the churn scenario deliberately busts
the cache and the warm scenario must not have that happening to it.

**Superseded by the harness v2 baseline below.** These numbers were measured with fixed
VUs — a closed model, whose arrival rate falls as the app slows down. The same app and
seed measured five times slower under an open model. They are kept because the
comparisons between scenarios still hold and because the record of what was measured,
and with what, is the point of this document.

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

*Invalidation is not the problem* — **is corrected below; the churn scenario measured
nothing.** As originally recorded: the churn scenario was built expecting the write
traffic to be the expensive part, measured no worse than warm on both machines (7.01 s
against 7.10 s on A, 1.53 s against 1.71 s on B), and was read as proof that rebuild
frequency barely matters.

**Correction (milestone 8.5 slice D).** The churn readers were real, but the writer that
was supposed to be busting the cache never landed a single like, so churn ≈ warm was a
warm cache compared with itself. Three defects compounded, found the first time a smoke
profile asserted that writes actually land:

1. The writer signed in during k6's `setup()` — whose cookie jar VUs never inherit — so
   the writer VU held no session.
2. A signed-out post page contains no authenticity token, so the token scrape found
   nothing and the writer returned without POSTing. Nothing checked the writer, so four
   green scenarios reported anyway.
3. Had it POSTed: the scrape read the page's *first form* token, and Rails issues
   per-form CSRF tokens scoped to one action — any other endpoint answers a silent 422.

What survives the correction: the dominant per-request cost is proven independently by
the telemetry — a cache **hit** costs 1.6 s of deserialization — so the improvement
target stands unchanged. What does not: how much invalidation adds under real write
traffic is an open question again, remeasured in slice G with the harness v2 load
profile, whose engager journeys sign in per VU, use the session-scoped meta token, and
assert every write landed. The `scenarios.js` writer is fixed the same way and now
checks `writer: like landed`.

The first run with the fixed writer suggests the answer will be different: at the 1k
seed on the sandbox machine, churn measured **2.5× warm** (301 ms against 119 ms avg,
p95 568 ms against 190 ms) the moment the writer's likes actually landed. Small seed,
slow machine — not a recorded finding, but reason to expect the 10k remeasurement to
overturn the original conclusion rather than confirm it.

Profile and search stay fast under the same concurrency, which is what makes the
comparison worth having: both scope and paginate in SQL, and neither holds a thread doing
Ruby work proportional to the size of the database.

**Not fixed here.** Milestone 8 measures. The improvements these numbers argue for — a
per-page cache rather than one whole-feed key, or scoring in SQL — land afterwards as
their own pull requests, each citing the number above that it moves.

## Harness v2: the profile suite

Milestone 8.5 slice D (F-8.5.1–3). The slice C suite above measures latency under a
closed model — fixed VUs that wait for responses, so the slower the app gets, the less
load the test sends, and the percentiles flatter it. The profile suite replaces it for
everything after milestone 8; the sections above stay as the record of what was measured
and with what.

```bash
script/stress-test smoke        # every journey once, strict gates — ~1 min
script/stress-test load         # 90-9-1 mix at a steady arrival rate — 5 min
script/stress-test breakpoint   # ramp the feed until the SLOs break — ~5 min
script/stress-test spike        # viral burst, then watch the recovery — ~4 min
script/stress-test              # the legacy slice C scenarios, unchanged budgets
```

Journeys, not endpoints. A reader loads the feed, pages it (`?page=1` — never exercised
by the old suite), opens a post, and checks a profile or searches; an engager does that
signed in, likes and replies; a creator signs in and posts. The mix is D-1's 90-9-1,
expressed as per-minute arrival rates. The load profile uses `constant-arrival-rate` —
an open model: iterations arrive on schedule whether or not the app has kept up, and
when k6 runs out of VUs it reports `dropped_iterations`, which is a capacity finding
rather than a harness artifact.

Every profile gates on error rate (`http_req_failed`) as well as latency, and every
check asserts page content — a run that serves errors, or serves the wrong page
quickly, cannot end green. Run `smoke` before any long profile: it is the gate that
would have caught the churn writer in one minute.

Three things the suite knows about the app, so runs do not trip over them:

- **Write profiles write.** Engagers reply, creators post. Reseed when a rerun must be
  strictly comparable.
- **Sign-in is rate-limited** — 10 per 3 minutes per IP, the app's own protection.
  Each profile keeps its signer count inside the limit (signed-in scenarios hold
  `maxVUs == preAllocatedVUs`); leave ~3 minutes between signing profiles or the second
  run's writers sit the run out.
- **Sessions persist across a VU's iterations** (`noCookiesReset: true`), because k6
  otherwise wipes each VU's cookies between iterations — the defect class that silently
  disarmed the old churn writer.

Rates and durations are environment variables with laptop-sized defaults — the knobs
(`READERS_PER_MIN`, `LOAD_DURATION`, `BREAKPOINT_MAX_RPM`, `SPIKE_RPM`, …) are listed at
the top of each profile in `script/stress/`. Every profile streams to Grafana Cloud with
`K6_MODE=stream`, arriving named `twitter-clone <profile> — <RUN_LABEL>`.

**VU pools are sized for a free Grafana Cloud project.** Cloud validates a test against
the *sum of every scenario's `maxVUs`* before it runs, and a free project allows 100 —
so the profiles declare 88 (load), 90 (breakpoint) and 90 (spike). The number is a pool,
not a target: an open model occupies roughly `arrival rate × latency` VUs, so the
breakpoint's 600/min against a 2-second feed needs about 20, and the pool only saturates
once responses pass ~9 seconds. Running out is reported as `dropped_iterations`, which
at that point *is* the capacity finding. For a local run that wants to push past the
cloud ceiling, raise it — `READERS_MAX_VUS`, `BREAKPOINT_MAX_VUS`, `SPIKE_MAX_VUS`:

```bash
BREAKPOINT_MAX_VUS=300 BREAKPOINT_MAX_RPM=2000 script/stress-test breakpoint
```

## Harness v2 baseline: the 10,000-post seed, open model

Milestone 8.5 slice G. Machine B (the Apple Silicon laptop), development server, the
same 10k seed the milestone 8 numbers came from, streamed to Grafana Cloud k6. **These
supersede the slice C numbers above**, which were measured under a closed model and are
optimistic by roughly a factor of five.

**There are two regimes, and the boundary is the finding.** Up to and past its knee the
app queues without failing — 0% `http_req_failed` and every content check passing in
both the load and breakpoint profiles, including the moment the ramp aborted. Push a
burst at it and that stops being true: the spike profile lost **31.7% of requests** to
timeouts. Slow degrades into unavailable somewhere between 3 and 8 requests a second.

### Load — the 90-9-1 mix at a steady arrival rate

54 reader journeys/minute, 5 engager, 1 creator, for five minutes. 1,182 requests,
1,084/1,084 checks passed, no errors.

| Journey | p90 | p95 | Budget |
| --- | --- | --- | --- |
| reader | 13.18 s | **13.75 s** | 2,000 ms |
| engager | 13.00 s | **13.56 s** | 2,000 ms |
| creator | 12.69 s | **13.19 s** | 2,000 ms |

Overall: avg **9.25 s**, median 9.76 s, max 15.47 s. Sustained throughput **3.58
requests/second**. A whole reader journey — four page loads — took an average of
**39.8 seconds**, p95 63 s, max 98 s. `dropped_iterations: 29`: k6 could not start
iterations on schedule because every VU was still waiting on the previous one.

**The closed model was hiding a factor of five.** The same app, seed and machine
measured 1.71 s average under slice C's five fixed VUs. Under an open model at 0.9
journeys/second it measures 9.25 s. Neither number is wrong; they answer different
questions. Fixed VUs ask "how slow is it when I only ever have five requests in
flight" — and because each VU waits for its response before sending again, the test
politely stops applying load exactly when the app starts struggling. Real arrivals do
not. **Every latency figure recorded in this document before this section understates
the problem, for that reason.**

### Breakpoint — where the feed stops coping

Feed reads only, ramping from 60 requests/minute towards 600 in five stages. The run
aborted itself 114 seconds in, on the p95 > 15 s gate, having reached the second stage.
Abort evaluation does not begin until 60 s, and p95 had already passed 15 s by then, so
**the knee is at or below 168 requests/minute — under 3 feed requests per second.**

| | value |
| --- | --- |
| median | 2.30 s |
| p90 | 13.62 s |
| p95 | 15.62 s |
| max | 17.55 s |
| errors | 0 of 236 |
| dropped iterations | 12 |

Median 2.3 s against a p95 of 15.6 s is the signature of a queue rather than a slow
page: some requests are served at the app's real speed while others sit behind them.
Which is what the arithmetic predicts — a feed request holds a thread for ~1.6 s of
CPU-bound deserialization, and there are three threads, so the feed can serve on the
order of two requests a second before arrivals start stacking up.

### Spike — where queueing becomes unavailability

A viral burst: 60 requests/minute for a minute, then **480/minute held for 90 seconds**,
then back to 60 for two minutes to watch the recovery. Eight requests a second against
an app that tops out under three — a deliberate 2.7× overload.

It did not cope.

| | value |
| --- | --- |
| requests lost | **90 of 284 — 31.7%** |
| p90 / p95 | **60 s / 60 s** (k6's request timeout — they never returned) |
| median (of those that answered) | 20 s |
| p95 (of those that answered) | 47.6 s |
| dropped iterations | **706**, against 284 completed |
| slowest journey | 2 m 11 s |

The shape, read against the stage clock: the VU pool saturated at **t=85 s**, fifteen
seconds into the burst. Timeouts began at **t=97 s** and ran until **t=145 s**. During
that window the app was, from a visitor's point of view, down — not erroring, which
would at least be quick, but silent: **no response at all inside sixty seconds**.

Two things worth being precise about.

**These are client-side timeouts, not server errors.** The app never returned a 5xx; it
simply did not answer in time. That is worse than an error, not better — a request that
errors releases its thread, while one of these is still occupying a thread while the
visitor has already given up. And k6 dropped 706 iterations it could not even start,
which means the real arrival rate the app failed to serve is more than double what
appears in `http_reqs`.

**It did recover.** The last timeout was at t=145 s, before load dropped back at
t=160 s, and nothing failed across the two-minute recovery window. So the app is not
left in a broken state by a burst — it comes back on its own once arrivals fall below
what it can serve. Whether latency returned to its ~2 s baseline or stayed elevated is a
question for the run's time series in Grafana; the aggregates here cannot answer it.

One harness caveat: the VU pool is 90 (the free Grafana Cloud project's ceiling). At
8 requests/second with responses taking a minute, no realistic pool would have kept up —
480 VUs would be needed — so the pool limit shaped the *numbers* but not the conclusion.
The app failing to answer within sixty seconds is the app's behaviour, not k6's.

### What this changes

The improvement target is unchanged but much better quantified, and the case for it is
now a capacity argument rather than a latency one:

- **Capacity is ~3.5 requests/second**, mixed, on a development server with three
  threads. Not concurrent users — requests per second, in total.
- **The feed alone tops out under 3 requests/second**, and past that, latency does not
  degrade gracefully; it climbs to 13–15 s within one ramp stage.
- **The failure mode is queueing until it is not.** Under sustained load the app
  answers everything, slowly. Under a burst it stops answering: a third of requests
  never returned. There is no error handling to fix here — both regimes have the same
  single cause, a request holding a thread for over a second — but the burst behaviour
  is what makes this worth fixing before anything is deployed rather than after.
- **A burst does not leave it broken.** It recovers by itself once arrivals drop.

Deserializing 20 post IDs and hydrating one page from the database should cost
milliseconds where the present code costs 1.6 s, so the fix is expected to move the
knee by an order of magnitude rather than a few percent. That is the claim the
re-run has to check.

**Caveats.** Development server, three threads, one process, one laptop, SQLite. The
*ratios* and the failure shape are the finding; the absolute ceiling belongs to this
setup. The production-shape target below removes the dev-mode overhead — and adds a
file-store cache, which will make the feed worse, not better. Deployment numbers come
from I-1g in the infrastructure repository.

## Decomposing the warm read: where the time actually goes

The load numbers say the feed is the bottleneck. This says why, by measuring the pieces
directly rather than inferring them from latency. Taken in the sandbox container at the
10,000-post seed (43,058 cached items, 4.75 MB), calling `RankedFeed` directly — no HTTP,
no view rendering, no concurrency, so the figures are lower than a request's and the
*ratios* are the point.

**Every page of the feed costs the same, and it is not the page.**

| | today |
| --- | --- |
| page 1 (first 20) | 763 ms |
| page 6 | 710 ms |
| page 51 | 716 ms |
| — of which, unpacking the cached blob | 798 ms |

Deserialization is the whole of it; `drop(page * 20).first(20)` on the resulting array
measures 0.0 ms. The cached value is one object holding every ranked item, and Ruby
cannot read part of it — the entire 4.75 MB is rebuilt into 43,058 objects before the
twenty being displayed can be picked out. **Page 51 costs what page 1 costs**, so a
reader scrolling pays the full price again on every scroll rather than amortising it.

The same measurement at the 1,000-post seed makes the scaling explicit:

| seed | cached items | warm read |
| --- | --- | --- |
| 1,000 posts | 4,083 | 71.9 ms |
| 10,000 posts | 43,058 | 763 ms |

10.5× the items, 10.6× the time. **The cost of serving twenty posts is proportional to
the number of posts in the database.** That is the defect in one sentence, and it is why
profile pages (`ProfileFeed`, 34.6 ms for a 669-post account) and search (0.7 ms) are
unaffected: both scope and paginate in SQL, so their cost tracks what they display.

### The fix, prototyped and measured

Ranking over plucked counter columns, caching the ordered `[post_id, reposter_id]`
pairs, and loading only the page being displayed — same ranking, same ordering, same
unlimited pagination, measured on the same data:

| | today | prototype | |
| --- | --- | --- | --- |
| cached value | 4.75 MB | **375 KB** | 13× smaller |
| page 1 | 763 ms | **10.9 ms** | **70×** |
| page 6 | 710 ms | **13.7 ms** | 52× |
| page 51 | 716 ms | **10.1 ms** | 71× |
| rebuild after any engagement write | 2,859 ms | **377 ms** | 8× |

The cached list still holds **all 43,058 entries in ranked order** — deep pagination is
unchanged, because what shrinks is the width of each entry, not the length of the list.

### Shipped, and measured against the same machine

The change landed as described (N-6.8). Both runs below are the sandbox
container, the same 10,000-post seed, the same profiles — the "before" taken by
reverting the two files and re-running, so nothing but the implementation
differs.

Direct calls, no HTTP:

| | before | after | |
| --- | --- | --- | --- |
| page 1 | 763.0 ms | **15.8 ms** | 48× |
| page 6 | 709.9 ms | **15.7 ms** | 45× |
| page 51 | 716.4 ms | **15.8 ms** | 45× |
| rebuild on a cache miss | 2,858.8 ms | **642.9 ms** | 4.4× |
| cached payload | 4.75 MB | **375 KB** | 13× |

**Breakpoint** — the ramp that previously aborted itself:

| | before | after |
| --- | --- | --- |
| outcome | aborted at 62 s | **ran the full 5 minutes to 600 req/min** |
| p95 | 29.37 s | **142 ms** |
| average | 14.24 s | **74.6 ms** |
| requests completed | 42 | **1,649** |
| dropped iterations | 14 | **0** |

**Load** — the 90-9-1 mix at 54 reader journeys a minute:

| | before | after |
| --- | --- | --- |
| requests failed | **47.3%** (195 of 412) | **0%** (0 of 1,334) |
| content checks passed | 51.2% | **100%** |
| average | 49.97 s | **468 ms** |
| median | 58.66 s | **106 ms** |
| p95 | 60 s (the timeout) | 2.53 s |
| throughput | 1.25 req/s | **4.41 req/s** |
| a whole reader journey | 2 m 56 s | **2.06 s** |

The sandbox is markedly slower than the laptop the earlier baseline came from,
which is why its "before" lost half its requests where the laptop's lost none
under the same profile. The comparison that matters is each column against the
other, on one machine.

The ranking is unchanged: recomputing the old ordering and comparing gives an
identical first 1,000 entries. Beyond that the two disagree, because 33,326 of
the 43,058 entries share a score with at least one other and `sort_by` is not
stable — two rebuilds of the *old* implementation disagreed with each other for
the same reason. Pre-existing, unchanged here, and worth a deterministic
tie-break if deep pagination across a rebuild ever needs to be reproducible.

**What is left, now that this no longer hides it.** The load profile still
crosses its 2-second p95 on the sandbox, with a median of 106 ms and a maximum
of 8 s — a fast page with an expensive tail. The tail is the rebuild: writes
bust the cache every few seconds, a rebuild is 643 ms, and readers arriving
during one all miss and each recompute the whole ordering. That is a cache
stampede, and it is the same question milestone 8 asked and could not answer,
because the churn writer never wrote. Single-flight rebuilds, or serving the
stale ordering while one rebuild runs, is the next measurable improvement.

**The remaining limit of the approach, stated rather than discovered later.** It
still deserializes the whole id list on every request, so its cost still grows with the
database — just with a constant 13× smaller. At 100,000 posts the list would be roughly
3.7 MB and the read would climb back into the tens of milliseconds. Caching per-page
slices, or moving the ranking into SQL, is what removes the growth rather than shrinking
it; neither is needed at the scales this project measures, and both are more machinery.
The 100k run (F-8.3) is what should decide whether that day has arrived.

## A production-shape target

Milestone 8.5 slice E (F-8.5.4). Capacity numbers taken against the dev server measure
code reloading, missing eager loading and verbose logging as much as the app.
`script/stress-server` runs the exact artifact the cluster will pull — the
`web/Dockerfile` image — locally, with a seeded named volume:

```bash
script/stress-server up 10000        # build the image, seed the volume, serve on :3001
RAILS_RUNNER="docker exec twitter-clone-stress bin/rails runner" \
  script/stress-test load http://localhost:3001
script/stress-server down            # stop; the volume and its data survive
script/stress-server reset           # delete the volume too — the next up reseeds
```

`RAILS_RUNNER` matters: fixture discovery must read the database of the app being
measured, and for the container that is the volume's, not the checkout's. Puma is tuned
through the production knobs (`RAILS_MAX_THREADS`, `WEB_CONCURRENCY` — set the latter to
the machine's core count for capacity runs). The dev server stays right for quick
iteration; a recorded run names its target.

Two things change under the production posture, and both matter when reading numbers:

- **The cache is a file store.** Development uses `:memory_store`; production leaves
  Rails' default `FileStore`, so every ranked-feed cache hit reads the multi-megabyte
  payload from disk before deserializing it. Dev-mode numbers *understate* the feed's
  cost — and a per-pod file store is what replicas would have had anyway, until the
  shared cache the infrastructure work already calls for.
- **Eager loading and quiet logs.** Boot does more, requests do less; per-request
  numbers stop including the code reloader.

Still one laptop: a breaking point found here describes the machine as much as the app.
Deployment numbers come from I-1g in the infrastructure repository.

## Traces to Grafana Cloud Tempo

Milestone 8.5 slice F (F-8.5.5). The k6 results already stream to Grafana Cloud
(`K6_MODE=stream`); this puts the server's side of the same story — request traces, and
the `ranked_feed.read` / `ranked_feed.rebuild` spans — next to them. It is configuration
only, which is the property ADR 0009 bought: nothing changes in the app.

Grafana Cloud portal → your stack → **OpenTelemetry** → note the OTLP endpoint (it looks
like `https://otlp-gateway-<region>.grafana.net/otlp`), your instance ID, and generate an
API token. Then:

```bash
OTEL_TRACES_EXPORTER=otlp \
OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp-gateway-<region>.grafana.net/otlp" \
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $(printf '%s' '<instance-id>:<token>' | base64 | tr -d '\n')" \
bin/rails server
```

The exporter appends the per-signal path (`/v1/traces`) itself. The same three variables
pass through `script/stress-server up`, so the production-shape target traces to the
same place. Exported spans arrive under service `twitter-clone-web`.

**Correlating a k6 run with its traces.** Both live in the same Grafana stack, so the
run's time range is the join: open the run (named `twitter-clone <profile> — <label>`),
note its window, then ask Tempo for the slow server work inside it — e.g.

```
{resource.service.name="twitter-clone-web" && name="ranked_feed.read" && duration > 1s}
```

— and the trace shows what that slow feed request actually spent its time on, with
`cache_hit` and `item_count` attributes on the span.

Two mechanics worth knowing:

- The batch processor exports every few seconds from a running server. A short-lived
  process (a runner, the seed) exits before the batch goes — call
  `OpenTelemetry.tracer_provider.force_flush` at the end if its spans matter.
- Verified locally against an OTLP sink: `OTEL_TRACES_EXPORTER=otlp` plus an endpoint
  is all it takes for spans to POST to `/v1/traces`. The Grafana Cloud round-trip needs
  the stack's credentials, so that last step is run by whoever holds them.

