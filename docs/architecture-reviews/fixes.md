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

## Finding 4 — nothing owned "a page of a timeline" (the 500s half)

**Pull request:** [#94](https://github.com/GauranshMathur/JDSG-Group6-app/pull/94) ·
**Issue:** [#86](https://github.com/GauranshMathur/JDSG-Group6-app/issues/86)

**What was wrong.** Both feed controllers carried the same unvalidated expression for the
page number, so both carried the same defect: `page=-1` reached `entries.drop(-20)` and
raised — a 500 on `/posts` and on every `/@username`, reachable by typing a URL.

**What replaced it.** `page_param` in the concern both controllers already include: one
reader, so one place refuses a bad value. Anything that is not a page number reads as the
first page; there is no ceiling, because a page past the end is a legitimate question with
an empty answer.

**What it cost.** Only the bug is fixed. The rest of finding 4 — one `Timeline` interface,
one `PAGE_SIZE` instead of three, one next-page protocol instead of three, splitting
`TimelinePagination`'s two halves — is structural, has no measurable behaviour change, and
is still open. Bundling it here would have buried a two-line fix inside a refactor and
muddied the measurement.

**Measured.**

| | Before | After |
| --- | --- | --- |
| `review_server_errors` | 6 | **0** |
| k6 exit code | non-zero (threshold crossed) | **0** |
| Checks succeeded | 99.64% | **100.00%** |

**Guard.** `spec/requests/timeline_paging_spec.rb`, red first. It also pins `page=0`,
`page=99999` and a non-numeric page, so the fix cannot trade one input for another.

**And the guard itself got a guard.** While measuring, one run had 31% of its requests
returning 500 and k6 still exited zero: `review_server_errors` is only incremented inside
the hostile scenario, so a 500 anywhere else was invisible to the exit code. The profile
now carries `checks: rate>0.99` and `http_req_failed: rate<0.01`. It has already earned
that twice — see the note under finding 6.

---

## Finding 6 — invalidation did not know what the ranking knows

**Pull request:** [#95](https://github.com/GauranshMathur/JDSG-Group6-app/pull/95) ·
**Issue:** [#88](https://github.com/GauranshMathur/JDSG-Group6-app/issues/88)

**What was wrong.** `compute_ordering` reads exactly two sets — top-level posts created
inside the window, and reposts made inside it — scored from each post's like, repost and
reply counters. `bust_cache` was bounded by neither: every like, every reply, every repost
on any post of any age marked the ordering stale, forcing a rebuild that returned a
byte-identical result.

**What replaced it.** `RankedFeed.ranks?` — the window predicate asked about one row, which
both sides now call. A post is ranked when it is top-level and either recent enough itself
**or carried in by a recent repost**. That second half is not a detail: **635 of this
corpus's 10,008 top-level posts are archived rows held in the window by a repost**, and a
naive `created_at >= cutoff` check would have silently stopped busting for every one of
them — trading a performance win for a stale feed.

**What it cost.** An archived post now pays one indexed `EXISTS` on the write path, where
before it paid nothing and made every reader pay for a rebuild. A recent post pays nothing:
the comparison short-circuits. On destroy the predicate is asked one beat late — an
archived post's reposts are already gone, so a row the ordering still names can answer
"not ranked" and skip a bust. That degrades correctly rather than silently: `hydrate`
already drops an entry whose post no longer exists.

**Where the review was wrong, and this is the interesting part.** Finding 6 said a reply
can never affect the ordering, because `top_level` guarantees a reply is never in it. True
of the reply itself — but a reply increments its **parent's** `replies_count`, and that
counter is a score input. So a reply to a ranked post *must* bust. Measured on this corpus,
**95.4% of replies land on a ranked row**, so the review's stated acceptance criterion —
"after the fix, both churn trends should sit at warm-feed levels" — was only ever going to
be true of one of them.

**Measured, deterministically.** The predicate is asked directly about real rows, so the
answer does not depend on the machine:

| | Before | After |
| --- | --- | --- |
| Ranked rows in the corpus | — | 2,912 of 10,008 top-level posts (29.1%) |
| A like on a random post busts | 100% | **33.0%** |
| A reply busts | 100% | 95.4% — correctly, its parent is usually ranked |

**Measured over HTTP**, `script/stress-test review` on the same seed snapshot:

| | Before | After |
| --- | --- | --- |
| Archive-churn feed, p95 | 246 ms | **62 ms** |
| Reply-churn feed, p95 | 250 ms | 215 ms — unchanged, as it should be |
| Warm feed, p95 | 122 ms | 156 ms |

Reading it: readers under archive churn are now **faster than the warm-feed reference**,
because they are served from cache instead of paying for rebuilds nobody needed. Reply
churn does not move, and now we know why.

**A caveat on the HTTP numbers, stated rather than buried.** During this fix's measurement
the container's SQLite began failing under load with `disk I/O error` — on queries as
small as `SELECT … FROM sessions WHERE id = 1`, which is not something application code
causes. Runs carried between 0 and 25% failed requests as a result, and the archive-churn
figure above is the median of four runs that each reproduced it (p95 of 62, 65, 80 and
115 ms against a 246 ms baseline). The deterministic table above is the load-bearing
evidence; the HTTP numbers agree with it. The new `http_req_failed` threshold is what
caught the instability at all — in one run every single check passed while a quarter of
requests were failing, because no check inspects a write request.
## Finding 5 — `ProfileFeed` materialised the whole archive to serve twenty rows

**Pull request:** [#96](https://github.com/GauranshMathur/JDSG-Group6-app/pull/96) ·
**Issue:** [#87](https://github.com/GauranshMathur/JDSG-Group6-app/issues/87)

**What was wrong.** Every post an account had ever written, plus every repost, loaded into
Ruby and sorted, to return twenty rows. The same pathology N-6.8 removed from the ranked
feed — recorded there at 763 ms — surviving untouched in the sibling service.

**Why the guard beside it never noticed.** `profile_query_budget_spec.rb` asserts a
constant *query count*, and the query count genuinely was constant: two queries at twenty
posts and two at two hundred thousand. It measured the axis that was not growing. Rows read
was the axis that was.

**What replaced it.** The two chronological streams — what the account wrote, what it
reposted — each ask for exactly the rows this page could contain, plus one. To take the top
N of a merge of two sorted streams you only need the top N of each, so the page's cost
tracks the page. The spare row answers "is there another page?" without a COUNT, the same
trick the ranked archive uses. Identifiers are merged first and posts loaded second, so
rows that lose the sort are never built into objects; the reposter needs no loading at all,
because on a profile it is always the account whose profile it is.

A profile needs no *window*, only a limit — it is chronological.
[ADR 0011](../adr/0011-ranked-window.md)'s "profiles never had a window and still do not"
is a statement about ranking and stays true.

**What it cost.** Deep pages are still linear in the page number: page 50 asks each stream
for 1,001 rows. That is the same shape as SQL `OFFSET` and is bounded by how far anyone
actually scrolls, but it is not free, and a true keyset cursor over the merged stream would
be. Not built, because nothing pages that deep today.

**Measured.** The heaviest account in the 10k seed — @user834, 882 posts and 30 reposts —
timed in-process over five runs, so the number is the service's own cost:

| | Before | After |
| --- | --- | --- |
| Profile page 1 | 63.5 ms | **4.5 ms** |
| Profile page 5 | 69.3 ms | **8.5 ms** |
| Post rows read, 20-post account | 20 | 20 |
| Post rows read, 100-post account | **100** | **20** |
| Repost rows read, 83 reposts | **83** | 3 |

The 63.5 ms agrees with the 63 ms already recorded for this account in
[`stress-testing.md`](../stress-testing.md), which is a useful check that the rig and the
old measurement agree.

Over HTTP the profile page's median moved from 71–89 ms across earlier runs to **51 ms**.
Smaller than 14×, and correctly so: the page also authenticates, preloads the viewer's
likes and reposts, and renders twenty posts of ERB, none of which this touches.

**Guard.** A new `RowCounter` helper and two examples in
`profile_query_budget_spec.rb`, red first: 20 rows read for 20 posts and 100 for 100, and
3 reposts read for 3 and 83 for 83. Both now constant. The helper exists because this
finding is a lesson about guards — a budget that measures the wrong axis passes forever.
