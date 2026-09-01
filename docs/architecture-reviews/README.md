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

| # | Finding | Review | Strength | Status |
| --- | --- | --- | --- | --- |
| 1 | "Load a post for rendering" has no module — 42 queries/page on tag and search | [2026-08-18](2026-08-18.md) | Strong | **Closed** — [#75](https://github.com/GauranshMathur/JDSG-Group6-app/pull/75), `Post.for_rendering`. 42 queries → 4; what it bought is in [`fixes.md`](fixes.md) |
| 2 | `Post.search` depends on the adapter; F-6.3 claims parity | [2026-08-18](2026-08-18.md) | Strong | Open |
| 3 | `Rails.cache` has no seam — rate limiter inert under test | [2026-08-18](2026-08-18.md) | Strong | Open |
| 4 | Nothing owns "a page of a timeline" — `?page=-1` is a 500 on two routes | [2026-08-18](2026-08-18.md) | Strong | Open |
| 5 | `ProfileFeed` materialises the whole archive to serve twenty rows | [2026-08-18](2026-08-18.md) | Strong | Open |
| 6 | Invalidation does not know the window; edits never bust the cache | [2026-08-18](2026-08-18.md) | Strong | Open |
| 7 | Image policy lives in a view; `Post#image_variants` is dead | [2026-08-18](2026-08-18.md) | Strong | Open |
| 8 | Like and Repost are one module written twice | [2026-08-18](2026-08-18.md) | Worth exploring | Open |
| 9 | One rule, several implementations — tags, usernames, the ranking formula | [2026-08-18](2026-08-18.md) | Worth exploring | Open |

When a finding is closed, mark it here with what closed it — a pull request, or the ADR
that refused it. A finding silently disappearing from this table is the failure mode this
table exists to prevent. What each fix actually changed, with its before/after numbers and
what they were measured on, goes in [`fixes.md`](fixes.md) — this table stays a status
column rather than growing into a changelog.

Findings 1–6 have load-side guards ahead of their fixes: the `review` k6 profile
(`web/script/stress/review.js`, run as `script/stress-test review`) exercises each one over
HTTP — the two 500s as a red gate, the rate limiter as a live refusal, tag/search/profile
latency and the churn comparison as recorded trends. The guards do not close a finding;
they are what a fix is measured against. Baselines in
[`docs/stress-testing.md`](../stress-testing.md).
