# ADR 0004 — Hashtags via a join table; search via `LIKE`

**Status:** Accepted
**Date:** 2026-07-29
**Milestones:** 5 and 6

## Context

Two features that look like the same problem — "find posts matching a string" — and are not.

A hashtag is a **known, enumerable entity**. `#rails` either is or is not attached to a post,
the set of tags is finite, and a tag page must list every post carrying it, exactly.

Search is **fuzzy and open-ended**. The query is arbitrary, results are ranked rather than
exact, and missing a marginal match is a quality problem rather than a bug.

Treating both as string matching would be the easy mistake.

## Decision

**Hashtags get a `Tag` model and a `PostTag` join.** Tags are parsed from the body when a post
is saved, normalised to lower case so `#Rails` and `#rails` are one tag, and looked up through
an indexed join.

**Search is a plain `LIKE` over post bodies and usernames**, behaving identically on SQLite and
PostgreSQL.

> **Amended 2026-09-01.** That last clause was aspirational when written: `Post.search` folded
> case on neither side, so it matched only because SQLite's LIKE ignores ASCII case, and it
> would have stopped matching the day the app moved to PostgreSQL. The decision — a plain
> `LIKE` rather than a search engine — is unchanged and still holds; what was untrue was the
> claim of parity. Both scopes now fold case in SQL and name an ESCAPE character
> ([#97](https://github.com/GauranshMathur/JDSG-Group6-app/pull/97)).

## Consequences

### Hashtags

**Good**

- `LIKE '%#rails%'` cannot distinguish `#rails` from `#railsconf`, and fixing that means
  anchoring on word boundaries the database does not agree about. A join answers exactly.
- Indexed lookup instead of a full scan with a leading wildcard, which no index can serve.
- Somewhere to hang tag metadata later — counts, following a tag, blocking one — without
  reworking the storage.

**Bad**

- Parsing runs on every save, and the tag set has to be reconciled when a post is edited.
- Two extra tables and a callback for something a `LIKE` would have approximated in one line.
- Normalising to lower case is lossy: `#RubyOnRails` and `#rubyonrails` become one tag, and
  the original casing is not preserved for display.

### Search

**Good**

- Works the same on both adapters, honouring N-1.2 — see [ADR 0003](0003-sqlite-first.md).
- No index to maintain, no extra dependency, no ranking to tune.
- Honest about what it is. A search that is deliberately basic and documented as such is better
  than one that looks smart and quietly misses results.

**Bad, and this is the real cost**

- `LIKE '%term%'` cannot use an index. It is a full table scan on every query, which is fine at
  this size and would not be at any real size.
- No ranking, no stemming, no relevance. "running" does not match "run". Results come back in
  timeline order, not by how well they match.
- No multi-word handling worth the name.

The good version of this needs PostgreSQL full-text search, which is exactly what ADR 0003
gave up. This is that decision's bill arriving, and it is deliberately being paid by a feature
in a proof of concept rather than by infrastructure everyone has to run.

## Revisiting

Search is the first thing to revisit once the app is actually on PostgreSQL. `tsvector`, a GIN
index and `websearch_to_tsquery` are a contained change — the interface stays "type a string,
get posts", so replacing the implementation should not touch the controller or the views.

Do not add a search engine — Elasticsearch, Meilisearch, `pg_search` — before that. The
capability wanted is already in the database the app is heading towards.
