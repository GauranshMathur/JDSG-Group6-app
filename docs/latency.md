# Latency and degradation

**Status: the query-count guard (§1) is built and asserting; everything else is
planned.** This is the write-up that comes before the work.

## Why this exists

Today the database is not on a network. SQLite runs inside the Rails process, so a query is a
function call — there is no round trip to be slow, and no failure mode between the app and its
data. Every latency problem this project could have is currently hidden by that.

The moment PostgreSQL runs in its own container, every query becomes a network round trip. The
goal is that the app **degrades in a way we understand and have measured**, rather than
discovering its behaviour the first time a network is slow.

Note what this is not: it is not making the app fast, and not making it survive a database
outage. It is knowing what happens, and having the numbers.

## What latency actually breaks

Roughly in the order it bites.

### 1. Query count stops being free

This is the multiplier that turns a small problem into a page-load problem. The feed issues
**two queries signed out and five signed in** — the page's posts and their reposters, then
the session lookup and the batched like and repost lookups — flat from one post to a full
page, measured warm against the 10k seed (N-6.1).

| Queries/request | At ~0.1ms (SQLite) | At 25ms | At 100ms |
| --- | --- | --- | --- |
| 2 | 0.2ms | 50ms | 200ms |
| 5 | 0.5ms | 125ms | 500ms |
| 21 | 2ms | 525ms | 2.1s |

Five is fine at any latency a healthy network produces — though the last column says a
signed-in feed over a 100 ms link is already at half a second, which is where the timeout
work below stops being theoretical. The 21-row is the textbook N+1 that milestone 3
made possible — `post.user` rendered per row — and it is the row the app is guarded
against: query counts are asserted in `feed_query_budget_spec.rb` and
`profile_query_budget_spec.rb` (N-6.2), so the regression fails the build rather than
being noticed as slowness. This was the cheapest guard in the document and the first
thing built from it.

### 2. The connection pool runs dry

A pooled connection is held for the whole round trip. Slower queries mean connections are held
longer, so under load the pool empties and requests queue for one — then raise
`ActiveRecord::ConnectionTimeoutError` once `checkout_timeout` (default 5 seconds) passes.

Today: Puma runs `threads 3, 3` and the pool is `RAILS_MAX_THREADS` defaulting to 5. Left
unset those are 3 and 5, which is fine. **Set, they become equal** — the exact minimum that
works, with nothing spare for anything else that takes a connection.

### 3. `timeout: 5000` quietly stops meaning anything

`config/database.yml` sets `timeout: 5000`. That is SQLite's `busy_timeout` — how long to wait
for a write lock. PostgreSQL ignores the key entirely.

So the single timeout currently configured is the one that disappears exactly when a network
shows up. PostgreSQL wants different knobs: `connect_timeout` for establishing the connection,
`checkout_timeout` for waiting on the pool, and a server-side `statement_timeout` so one slow
query cannot hold a connection indefinitely.

### 4. `/up` reports healthy when the database is not

Rails' health endpoint deliberately does not check dependencies. From its own source:

> This endpoint does not reflect the status of all of your application's dependencies, such as
> the database or Redis cluster.

With PostgreSQL unreachable, `/up` still returns 200, a load balancer keeps routing to the
container, and every request fails. Worth being careful here: that default is *defensible* —
restarting the app because a third party is down makes an outage worse. So the answer is a
separate dependency-checking endpoint for readiness, not changing what `/up` means.

### 5. Nothing gives up at the top

Puma has no request timeout by default. A request blocked on a slow query holds one of three
threads until the database answers. Three of those and the app serves nothing — while still
reporting itself healthy, per the point above.

## The knobs

| Setting | Where | Today | Under latency |
| --- | --- | --- | --- |
| `pool` | `database.yml` | `RAILS_MAX_THREADS`, default 5 | Must be ≥ Puma threads, with headroom |
| `checkout_timeout` | `database.yml` | unset (5s default) | How long a request waits for a free connection before raising |
| `connect_timeout` | `database.yml` | unset | Caps how long establishing a connection can hang |
| `statement_timeout` | `database.yml` `variables:` | unset | Server-side cap so one query cannot hold a connection forever |
| `timeout` | `database.yml` | 5000 | **SQLite only** — ignored by PostgreSQL |
| `threads` | `puma.rb` | 3, 3 | Concurrency ceiling; each busy thread holds a connection |
| health check | `routes.rb` | `/up`, no dependency check | Reports healthy with a dead database |

## How we would test it

**SQLite cannot be tested this way** — in-process, no wire, nothing to slow down. So this work
requires the PostgreSQL path, which today is an *untested claim*: no CI job has ever run the
suite against PostgreSQL, as recorded in [open questions](open-questions.md) and
[ADR 0003](adr/0003-sqlite-first.md). Verifying the switch and testing latency are the same
piece of work, which is a good reason to do them together.

**Proposed harness: [Toxiproxy](https://github.com/Shopify/toxiproxy) between app and
database.** The app connects to `toxiproxy:5432`, which forwards to `postgres:5432`. Latency,
jitter, timeouts and connection drops are toggled through an HTTP API *while the stack is
running*, so every scenario runs against one compose stack with no restarts and no rebuilds.

Considered and rejected: `tc`/netem inside the container. It needs `NET_ADMIN`, applies to all
traffic rather than just the database connection, and has to be reconfigured per scenario.
Worth revisiting only if we also want to shape the HTTP side.

**Scenarios**, each run against the same seeded data:

| # | Condition | What we expect to learn |
| --- | --- | --- |
| 0 | No proxy, SQLite | The baseline we have today |
| 1 | Postgres, 0ms added | The cost of the network existing at all |
| 2 | +25ms | A plausible same-region round trip |
| 3 | +100ms | Cross-region, or a bad day |
| 4 | +100ms ±50ms jitter | Whether variance breaks anything constant latency does not |
| 5 | Connection blackholed | What the user sees, and what `/up` claims |

**Measured per scenario:** page latency p50/p95, queries per request, error count and class,
and — for scenario 5 — the gap between what the health check says and what is true.

The point of writing the numbers down is that "it feels slow" is not a finding and cannot be
compared against the next change.

## Deliberately out of scope

Circuit breakers, retry budgets, read replicas, pgbouncer, and caching. Each is a real answer
at real scale, and each needs operational understanding this project does not have. Adding
them now would be building machinery for a load that does not exist — and untested resilience
machinery is worse than none, because it is believed.

## Measured so far

Step 1 is done. Injecting a fixed 100ms into every query and timing one feed render, signed
in, with a full page of 20 posts:

| | Queries | Page render |
| --- | --- | --- |
| Before | 4 | 439 ms |
| After | 2 | 240 ms |

The two that went were both avoidable, and neither was visible on SQLite:

- **A `COUNT`.** `next_cursor_for` asked the relation for its `size` before it had loaded, so
  Active Record counted the rows and then fetched the same rows again to render them.
- **A `users` lookup.** Almost every authenticated request reads `Current.user` — the masthead
  alone does — but the session was fetched without it, so the user arrived in a second round
  trip. `eager_load` makes it one join. This one was introduced by milestone 2.

Neither is a large win at 0.1ms. Both are half the page at 100ms, which is the whole point:
**query count is invisible until it is expensive, and by then it is everywhere.**

## Proposed order

1. ~~**N+1 guard.** Assert query counts in request specs.~~ **Done** — `feed_query_budget_spec.rb`
   asserts the count is flat from one post to a full page, signed in and out, and that no
   `COUNT` is issued to decide the pagination link. Milestone 3's N+1 will fail it.
2. **Explicit timeouts, and pool sized above threads.** Replace the SQLite-only `timeout` with
   settings that mean something on both adapters.
3. **A readiness endpoint that checks the database**, separate from `/up`.
4. **The Toxiproxy harness and a measured baseline**, which also settles whether the
   "PostgreSQL is one environment variable" claim is true.

Steps 1 to 3 are small and useful regardless. Step 4 is the real experiment.
