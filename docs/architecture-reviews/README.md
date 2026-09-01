# Architecture reviews

A review per pass over the codebase looking at **module depth** — how much behaviour sits
behind each interface, and where knowledge has ended up with no module to own it. Each one
is a snapshot: what was true on a given commit, what it cost, and what was recommended.

## How this differs from an ADR

An [ADR](../adr/) records a decision that was taken. A review records **friction that was
found**, before anyone has decided what to do about it. A review candidate that gets
argued through and accepted usually *becomes* an ADR; one that gets rejected for a
load-bearing reason should also become an ADR, so the next review does not re-suggest it.

The two therefore age differently. ADRs are immutable once accepted, because the reasoning
is the point. Reviews go stale on purpose — a finding is expected to be fixed, and the
index below is what tracks whether it was.

## Naming

Reviews are named by date, `YYYY-MM-DD.md`, not numbered like ADRs. A decision's identity
is its number; a snapshot's identity is when it was taken, and dates sort chronologically
without anyone having to check what the last one was.

## Reviews

| Review | Against | Focus | Top recommendation |
| --- | --- | --- | --- |
| [2026-08-18](2026-08-18.md) | `main` @ 42981ac, after milestones 8–8.7 | Module depth across the feed, timelines, search and image handling | Give "load a post for rendering" a module |

## Open findings

Carried across reviews until each is closed. A finding closes by being fixed, or by an ADR
recording why it will not be.

| # | Finding | Review | Strength | Issue | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | "Load a post for rendering" has no module — 42 queries/page on tag and search | [2026-08-18](2026-08-18.md) | Strong | [#83](https://github.com/GauranshMathur/JDSG-Group6-app/issues/83) | **Closed** — [#92](https://github.com/GauranshMathur/JDSG-Group6-app/pull/92) |
| 2 | `Post.search` depends on the adapter; F-6.3 claims parity | [2026-08-18](2026-08-18.md) | Strong | [#84](https://github.com/GauranshMathur/JDSG-Group6-app/issues/84) | Open |
| 3 | `Rails.cache` has no seam — rate limiter inert under test | [2026-08-18](2026-08-18.md) | Strong | [#85](https://github.com/GauranshMathur/JDSG-Group6-app/issues/85) | Open |
| 4 | Nothing owns "a page of a timeline" — `?page=-1` is a 500 on two routes | [2026-08-18](2026-08-18.md) | Strong | [#86](https://github.com/GauranshMathur/JDSG-Group6-app/issues/86) | **Part closed** — the 500s by [#94](https://github.com/GauranshMathur/JDSG-Group6-app/pull/94). The `Timeline` interface, one `PAGE_SIZE` and one next-page protocol remain |
| 5 | `ProfileFeed` materialises the whole archive to serve twenty rows | [2026-08-18](2026-08-18.md) | Strong | [#87](https://github.com/GauranshMathur/JDSG-Group6-app/issues/87) | **Closed** — [#96](https://github.com/GauranshMathur/JDSG-Group6-app/pull/96). 63.5 ms → 4.5 ms; rows read now bounded by the page ([`fixes.md`](fixes.md)) |
| 6 | Invalidation does not know the window; edits never bust the cache | [2026-08-18](2026-08-18.md) | Strong | [#88](https://github.com/GauranshMathur/JDSG-Group6-app/issues/88) | **Closed** — [#95](https://github.com/GauranshMathur/JDSG-Group6-app/pull/95). Half the finding was wrong about replies, and the edit half needed no fix; both recorded in [`fixes.md`](fixes.md) |
| 7 | Image policy lives in a view; `Post#image_variants` is dead | [2026-08-18](2026-08-18.md) | Strong | [#89](https://github.com/GauranshMathur/JDSG-Group6-app/issues/89) | Open |
| 8 | Like and Repost are one module written twice | [2026-08-18](2026-08-18.md) | Worth exploring | [#90](https://github.com/GauranshMathur/JDSG-Group6-app/issues/90) | Open |
| 9 | One rule, several implementations — tags, usernames, the ranking formula | [2026-08-18](2026-08-18.md) | Worth exploring | [#90](https://github.com/GauranshMathur/JDSG-Group6-app/issues/90) | Open |

Findings 8 and 9 share an issue: both are one concept expressed more than once, both are small,
and splitting them would have produced two tickets nobody picks up rather than one.

**The table is the record; the issue is the queue.** A finding stays here whatever happens to its
issue, because an issue closed as \"not doing this\" is still a thing that was found. When a finding
is closed, mark it here with what closed it — a pull request, or the ADR that refused it. A finding
silently disappearing from this table is the failure mode this table exists to prevent.
What each fix actually changed, with its before/after numbers and the rig they were measured
on, goes in [`fixes.md`](fixes.md) — this column stays a status rather than growing into a
changelog.

Findings 1–6 also have load-side guards ahead of their fixes, in the `review` k6 profile — see
[`docs/stress-testing.md`](../stress-testing.md) for what each one measures today.

Findings 1–6 have load-side guards ahead of their fixes: the `review` k6 profile
(`web/script/stress/review.js`, run as `script/stress-test review`) exercises each one over
HTTP — the two 500s as a red gate, the rate limiter as a live refusal, tag/search/profile
latency and the churn comparison as recorded trends. The guards do not close a finding;
they are what a fix is measured against. Baselines in
[`docs/stress-testing.md`](../stress-testing.md).
