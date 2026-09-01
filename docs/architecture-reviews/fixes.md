# Review fixes — what changed, and what it bought

One entry per finding fixed, newest last. The [README](README.md) tracks *whether* a
finding is open; this file records **what the fix did and what it measurably changed**, so
a number in a pull request has somewhere to live afterwards.

Each entry says: what was wrong, what replaced it, what it cost, and the measurement.
An entry with no measurement is allowed only where the finding has nothing to measure —
and it has to say so rather than leaving the row blank.

## How the measurements are taken

Every performance figure here comes from the same rig, so the columns are comparable:

- **Corpus**: one 10,000-post seed (`bin/rails runner script/seed-load-test 10000`),
  snapshotted to a file the moment it finished — 26,515 posts, 836 users, 110,363 likes,
  33,050 reposts. Every run restores that snapshot first, because the profile writes as it
  goes and a second run would otherwise start from a different database.
- **Profile**: `script/stress-test review`, the guard profile built for these findings.
- **Server**: `bin/rails server` in development, 3 Puma threads, same machine, runs
  back to back.
- **Before and after are separate runs of the same profile against the same snapshot**, one
  on `main` and one on the fix branch, using a git worktree per branch so neither run has to
  wait for a checkout.

What that rig is *not*: it is a development server on one machine, so the absolute
milliseconds describe this laptop and not production. Differences between two runs on it
are meaningful; the numbers themselves are not capacity planning. Run-to-run variance on
the unaffected scenarios is roughly ±25% at p95, which is the noise floor any claim here
has to clear.

---

## Finding 1 — "load a post for rendering" had no module

**Pull request:** [#92](https://github.com/GauranshMathur/JDSG-Group6-app/pull/92) ·
**Issue:** [#83](https://github.com/GauranshMathur/JDSG-Group6-app/issues/83)

**What was wrong.** The chain `.includes(user: { avatar_attachment: :blob },
images_attachments: :blob)` was written out five times, missing entirely from the tag and
search controllers, and present in a drifted form on the reply error path (author
eager-loaded, attachments not). The two pages missing it were exactly the two pages with no
query-budget spec — the absent module and the absent guard were the same gap, which is why
nobody noticed the pages cost **42 queries to render twenty rows** against the feed's 4.

**What replaced it.** One scope, `Post.for_rendering`, holding everything a rendered post
row touches: the author joined into the post query, the author's avatar and the post's
images preloaded. `Post.timeline` composes it, so every timeline gets it by construction;
detail pages name it directly. Eight call sites now say what they want instead of
respelling how to get it.

**What it cost.** One respelling survives: `ProfileFeed`'s repost branch preloads through a
nested `post:` association, and `includes` cannot name a scope on a nested association. It
is marked in place as the copy to change if `for_rendering` changes — a real seam that the
fix does not close, rather than one quietly left out of the description.

**Measured.**

| | Before | After | Change |
| --- | --- | --- | --- |
| Queries, tag/search page, 20 rows | **42** | **4** | −38 queries |
| Queries, tag/search page, 1 row | 4 | 4 | unchanged |
| Tag page, median | 66.8 ms | **36.1 ms** | −46% |
| Tag page, p95 | 124.4 ms | **96.5 ms** | −22% |
| Search page, median | 85.0 ms | **33.9 ms** | −60% |
| Search page, p95 | 207.3 ms | **91.8 ms** | −56% |
| Warm feed, median | 30.1 ms | 30.5 ms | flat, as intended |
| Profile page, p95 | 122.8 ms | 153.8 ms | within noise |
| Reply-churn feed, p95 | 249.9 ms | 228.2 ms | within noise |

Read it this way: **the two pages that were missing the preload got faster and nothing else
moved.** That is the shape a correct fix should have — the feed and profiles already had
the chain, so they had nothing to gain, and the movement on those rows is inside the ±25%
noise floor rather than evidence of anything. Search, the slowest read page in the app
before this, is now the fastest of the three.

The query counts are the authoritative half. Latency on SQLite understates the win badly:
38 extra round trips to a local file cost tens of milliseconds, while the same 38 across a
network — which is what `DATABASE_URL` pointing at PostgreSQL means — cost tens of
milliseconds *each*. The guard that keeps it fixed is a query-count spec, not a timing.

**Guard.** `spec/requests/timeline_query_budget_spec.rb` — tag and search must cost the
same number of queries at twenty rows as at one. It is the tag/search equivalent of the
feed and profile budgets that already existed, which is the reason this was found at all.

---

## Finding 2 — `Post.search` depended on the adapter

**Pull request:** [#97](https://github.com/GauranshMathur/JDSG-Group6-app/pull/97) ·
**Issue:** [#84](https://github.com/GauranshMathur/JDSG-Group6-app/issues/84)

**What was wrong.** `User.search` folded case on both sides — the query by `downcase`, the
column by the normalisation on write. `Post.search` folded neither, and post bodies are
stored verbatim, so it matched only because SQLite's `LIKE` ignores ASCII case.
PostgreSQL's does not. Three documents recorded parity that did not exist: F-6.3 as met,
[ADR 0004](../adr/0004-hashtags-and-search.md) in its opening claim, and `CLAUDE.md`'s rule
against adapter-specific behaviour.

**How it was made visible.** This is the interesting part of the finding: the defect cannot
be seen on the adapter we run, so a case-insensitivity example passes whether or not the bug
is present — the existing `search_spec.rb:18` did exactly that. `PRAGMA
case_sensitive_like = ON` makes SQLite compare the way PostgreSQL will, and under it the
specs fail before the fix and pass after. The switch is no longer the thing that discovers
this.

**What replaced it.** Both scopes fold case in SQL and name an ESCAPE character.

**A second defect the specs found on the way.** `sanitize_sql_like` escapes `%` and `_`
with a backslash, but SQLite gives `LIKE` no default escape character — so the backslash was
matched literally and **searching for "100%" found nothing at all**. PostgreSQL happens to
default to backslash, so this was the mirror image of the case bug: a search that worked
there and not here. Both scopes now name the escape explicitly, which is the only spelling
that means the same thing on both.

**What it cost.** `LOWER(posts.body)` cannot use an index on `body` — but nothing could:
a `LIKE '%term%'` with a leading wildcard never uses one, which is the cost ADR 0004
already accepted. Case folding is ASCII-only, because that is what both databases' `LOWER`
does without a collation; a Turkish dotted capital still will not match its lowercase form,
recorded rather than implied.

**Measured.** Nothing to time — this is a correctness fix, and the honest report is what it
is guarded by:

| | Before | After |
| --- | --- | --- |
| Specs for either search scope | **none** | 8 |
| `Post.search` under PostgreSQL-like comparison | 4 failing | passing |
| Searching for a literal `%` or `_` | finds nothing | finds the post |
| Proven against a real PostgreSQL | no | **still no** — no CI job runs one |

That last row is why F-6.3 now says met *and* names what is still unproven. Simulating an
adapter is not the same as running against it, and the fix does not pretend otherwise.
