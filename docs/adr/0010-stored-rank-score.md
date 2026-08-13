# ADR 0010 — The ranking is a stored, indexed column, ordered by the database

**Status:** Proposed
**Date:** 2026-08-12

## Context

The ranked feed has been measured, improved twice, and measured again. Both improvements
made the same cost smaller without changing its shape: **the work of serving twenty posts
is proportional to the number of posts in the database.**

| | at the 10k seed | still proportional to the whole timeline? |
| --- | --- | --- |
| serving a page | 763 ms → 16 ms (N-6.8) | **yes** |
| rebuilding the ordering | 2,859 ms → 643 ms (N-6.8) | **yes** |
| how often a rebuild ran | ×N readers → ×1 (F-8.6.1) | no |

The projection in [`docs/stress-testing.md`](../stress-testing.md), anchored against the
measured 10k figure, puts serving a page at ~190 ms once the timeline reaches 430,000
entries — a 100,000-post seed. That is the common path, taken by the ~90% of traffic that
only reads ([`design-principles.md`](../design-principles.md)).

**Why it is computed in Ruby at all.** The score is

```
(likes + 2·reposts + replies + 1) / (age_hours + 2)^1.5
```

which divides by *current* age, so every post's score changes every second. Nothing about
it can be indexed, and nothing about it can be usefully stored: a written value is stale
before the next request. Computing all of it on read and caching the answer is the natural
response to that formula, and it is the formula — not the caching — that forces the shape.

A second consequence, already visible: 33,326 of the 43,058 entries at the 10k seed share
a score with at least one other entry, and `sort_by` is not stable, so two rebuilds
disagree about the tail. Deep pagination across a rebuild is not reproducible today.

## Decision

**Store the ranking as an indexed column and let the database order and limit.**

Three changes, in this order, because each depends on the one before it:

1. **The time term becomes a constant fixed at creation** rather than a divisor over
   current age — the shape Hacker News and Reddit use, `f(engagement) + created_at/k`.
   A post's score then changes only when its engagement changes.
2. **`posts.rank_score`**, indexed, written when a post is created and whenever its
   like, repost or reply counts change. The counter caches those need already exist.
3. **The feed becomes `ORDER BY rank_score DESC, id DESC LIMIT 20`** — an index read of
   twenty rows, with keyset pagination on `(rank_score, id)`.

What that deletes: the ordering cache, the stale marker, the rebuild lock, the rebuild
itself, and `RankedFeed.warm` on boot. Serving a page stops depending on how many posts
exist, so the projection above stops applying at any scale. The tie instability goes with
it, because `id` breaks ties deterministically.

## Cost

**The ranking behaves differently, and someone will notice.** Today an old post that
suddenly attracts engagement climbs steeply, because it is divided by an age that has
stopped growing quickly in relative terms. With an additive time term its position is
anchored near where it was created, and engagement lifts it less. Whether that is better
is a product judgement about what the feed is *for*, and this ADR does not settle it — it
only records that the two are not the same feed.

**Writes get heavier, on the path that is 10% of traffic.** Every like, repost and reply
now updates a column and an index in addition to its counter cache. Cheap individually,
and it is the trade the 90-9-1 rule argues for, but it is not free and it lands on the
path where a user is waiting for their own action to complete.

**A migration on the largest table**, plus a backfill, plus a second index on `posts`.

**Correctness moves from one place to many.** Today the ranking is computed in one method,
so it cannot disagree with itself. Afterwards it is maintained incrementally by callbacks
on three models, and any path that changes engagement without updating `rank_score` — a
bulk import, a `delete_all`, a future feature, the load-test seed's own `insert_all` —
leaves rows ranked wrongly, silently and indefinitely. That is the real cost of this
decision, and it needs a way to detect drift rather than a promise to remember.

**It forecloses ranking changes that need current time.** Any future ranking that must
re-evaluate continuously — "trending in the last hour" — cannot use a stored column, and
would need this decision revisited rather than extended.

## Alternatives considered

**Compute the score inline in SQL** — `ORDER BY (likes_count + …) / POWER(…, 1.5)`.
Measured at the 10k seed: **3.7 ms** to return the top twenty ids, against 16 ms for the
current cached read, with no cache at all. Rejected on two counts. It uses `julianday()`
and `POWER()`, which PostgreSQL spells differently, and N-1.2 requires the PostgreSQL
switch to stay a single environment variable with no code change. And its query plan is
`USE TEMP B-TREE FOR ORDER BY` — it sorts every top-level post on every request, so the
proportionality survives, merely executed in C instead of Ruby. It is the cheaper diff
and the shorter-lived answer.

**Cache the ordering in page-sized chunks** rather than one key. Serving a page becomes
constant, but a rebuild still materialises the whole ordering, invalidation has to bust
every chunk, and the machinery grows rather than shrinks. It treats the symptom this ADR
removes.

**Leave it.** Entirely defensible for a proof of concept that will never hold 100,000
posts. The counter-argument is that the app is measured, the measurement says the shape is
wrong, and the infrastructure track is about to run it on a cluster where "it is fine at
our scale" stops being checkable by one person on a laptop.

## Open, and deliberately not decided here

- **The exact formula and the value of `k`.** The one this ADR points at is a family, not
  a specific ranking, and choosing within it is the product judgement above.
- **How drift is detected.** A periodic reconciliation, a spec that recomputes and
  compares, or an assertion in the load-test seed. Something has to, or the failure mode
  is silent.
- **Whether `RankedFeed` survives as a class.** With ordering in SQL there may be little
  left of it worth keeping.
