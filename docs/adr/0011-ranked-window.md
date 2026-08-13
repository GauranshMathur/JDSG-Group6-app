# ADR 0011 — The ranking considers a recent window; the feed continues into the archive

**Status:** Accepted
**Date:** 2026-08-13

## Context

The ranked feed scored every entry the database holds to serve twenty posts, so its cost
grew with the corpus: measured at ~43,000 entries for the 10k seed, projected at ~190 ms
a page by 430,000 ([ADR 0010](0010-stored-rank-score.md), still proposed). Sites that
serve far more traffic than this app ever will — Hacker News, Reddit's front page — never
meet that problem, because they never rank their full archive: they rank a bounded,
recent candidate set.

The measurement also said the unbounded ranking was not buying a good feed: at the 10k
seed, none of the top twenty entries was from the last seven days. All of the cost, none
of the freshness.

## Decision

**Only what happened inside a window — `RankedFeed::WINDOW`, 7 days — competes for the
top of the feed.** A post enters by being created; an old post re-enters by being
reposted, because the repost is a recent event even when the post is not. The scored,
sorted ordering is cached together with the cutoff that bounded it.

**The feed then continues into the archive: everything older, newest first**, served
straight off the `(created_at, id)` index, twenty rows at a time. The page where the
window meets the archive asks one bounded `LIMIT` question — never a `COUNT`, because a
count is O(archive) and the archive is the part that grows without bound.

**Nothing is removed.** Search, profiles, tag pages and the post's own page never had a
window and still do not; the feed itself remains unlimited scroll. An old post stops
being *ranked*, not being *shown*.

Rebuild and page cost now track the recent write rate instead of the size of the
database. The corpus can grow for years; the ranking's work is bounded by one week of
activity.

## Cost

**Likes no longer resurface old posts.** Under the old formula, an old post attracting
likes could climb back into the feed; now only a fresh repost re-enters it. That is a
ranking change someone will notice, and it makes reposting the sole road back — a
product judgement this record takes, where [ADR 0010](0010-stored-rank-score.md)
deliberately left its own version of the same judgement open.

**Seven days is a guess, not a measurement.** The window is a product knob. Too short
and a quiet week leaves the ranked section thin — the feed never renders empty, because
the archive follows immediately, but its top loses curation. Nothing warns when that
happens.

**Bounded by activity is not constant.** A viral week is a big window; the rebuild
still scores and sorts everything in it. The cost now scales with success-per-week
rather than success-since-launch, which is the improvement, not a ceiling.

**The machinery survives.** The ordering cache, the stale marker and the rebuild lock
all stay, merely with a bounded input. The stored score would delete them; this decision
defers ADR 0010 rather than settling it.

**Deep archive pages pay `OFFSET`**, which walks the index in proportion to how far one
person has scrolled — not to the size of the corpus. Keyset pagination
([ADR 0002](0002-keyset-pagination.md)) would remove even that, but the ranked feed's
pagination has been positional since it became an ordering, and a cursor cannot address
a position inside a ranked list that reorders on every rebuild. Accepted.

**Repost duplication survives inside the window.** A post heavily reposted *this week*
still occupies one slot per repost — the open question recorded in
[`open-questions.md`](../open-questions.md) is narrowed by the window, not answered.

## Alternatives considered

**The stored, indexed score** ([ADR 0010](0010-stored-rank-score.md)) — constant-time
ordering by the database, at the price of a different ranking shape, callbacks on three
models, and a drift-detection obligation. Not rejected: deferred. It should be judged
against measurements taken *after* this window and after the duplication question is
answered, since both change every number it was proposed on.

**Leave it.** Rejected by its own measurement: the unbounded ranking cost work
proportional to the corpus and still put nothing fresh in the top twenty. Paying more
for a worse feed is the one combination with nothing to recommend it.
