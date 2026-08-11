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

**Not fixed here.** Milestone 8 measures. Improvements land afterwards as their own pull
requests, each citing the number above that it moves.
