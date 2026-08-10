# Open questions

Decisions not yet taken. This is a **live list** — when work answers a question, it is deleted
from here and the answer moves into whichever document it belongs to. It is not a log of
things we once wondered about.

Each entry says what the question is, why it matters, and when it needs answering. A question
with no "when" tends to sit here forever; a question with one becomes a decision on time.

Answered decisions live in [`adr/`](adr/) when the trade-off is worth remembering, or in the
relevant document when it is not.

---

## Product

### Should an edit history be kept?

**Partly answered.** Milestone 3 ships an "edited" marker — a post that has changed says so.
What it does *not* keep is the previous wording, so an edit is visible but not inspectable.

**Why it matters:** the marker was the cheap half. A history is the half that cannot be added
retroactively: every edit made from now until it exists is one whose earlier version is
already gone. The cost of leaving this open is accruing, which is not true of most of the
questions on this page.

**When:** before anything invites real usage. It is cheap while the table is small.

### Is there a time limit on editing?

Milestone 3 ships no limit — a post can be rewritten a minute or a year after publication.

**Why it matters:** it is the difference between fixing a typo and rewriting history, and it
matters more now that replies exist, because a reply can be made to agree with something that
is then changed underneath it.

**When:** overdue. The original deadline was "before replies ship", and replies shipped in
milestone 5 with no limit decided — every post remains editable forever. Needs answering
before anything invites real usage.

### Should duplicate posts be prevented?

For example by hashing the body and rejecting a repeat from the same author within a window.

**Why it matters:** double-submits happen, and a feed showing the same post three times is
bad. But "duplicate" needs defining — the exact same text, or normalised for whitespace and
case? Someone posting "good morning" every day is not spamming.

**When:** not urgent. Worth deciding before anything invites real usage.

---

## Technical

### Ranked full-text search

Milestone 6 ships a `LIKE` search, because full-text search is adapter-specific and the app is
on SQLite — see [ADR 0004](adr/0004-hashtags-and-search.md).

**When:** once the app is actually on PostgreSQL. Not before, and not by bolting on a search
engine to avoid the move.

### Is the PostgreSQL switch actually verified?

[ADR 0003](adr/0003-sqlite-first.md) claims switching databases needs only an environment
variable. Nothing tests that claim — no CI job runs the suite against PostgreSQL.

**Why it matters:** an untested claim about portability is a guess, and adapter assumptions
get found at the worst possible moment.

**When:** it now has a date. The latency work in [`latency.md`](latency.md) cannot start
without PostgreSQL, because SQLite runs in-process and there is no network to slow down. So
verifying the switch and measuring latency are one piece of work, not two. Tracked as N-6.7.

### How does the app degrade when the database is slow?

Not a single question so much as a set of them, written up in [`latency.md`](latency.md):
query counts, pool exhaustion, timeouts that only apply to SQLite, and a health check that
reports 200 against a dead database.

**Why it matters:** none of it is visible today, because SQLite is in-process. All of it
appears at once the first time PostgreSQL runs in its own container.

**When:** steps 1 to 3 of that document are small and worth doing regardless — in particular
the query-count guard, which should land before milestone 3 creates the N+1 it exists to
catch. The measurement harness is a separate, larger piece.

---

## Infrastructure

Tracked in [JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra/blob/main/docs/open-questions.md), along with the
decisions behind it. Three of them force a change *here* when they are answered — PostgreSQL,
a shared cache to replace the per-process one, and S3 for Active Storage — and each is made
when it blocks, not before.

---

## Delivery

### Required status checks and up-to-date branches

`main` has neither. Auto-merge cannot arm without required checks, so every merge is manual;
and since CI no longer runs on `main`, nothing re-validates a merge commit.

**Why it matters:** two branches can each pass in isolation and still break once merged, and
the release will ship it.

**When:** now. This is configuration rather than work — see N-4.2 and N-4.2a in
[`REQUIREMENTS.md`](../REQUIREMENTS.md).

**Only `SAST` is safe to require today.** `ci.yml` is filtered by `paths` on its trigger, and
a workflow that is never triggered reports nothing at all — so requiring `Lint` would leave
every documentation-only pull request waiting forever for a status that is never coming.
`security.yml` is deliberately unfiltered, so `SAST` is always present. Requiring anything
from `ci.yml` needs either a change of shape or an always-running aggregate job. See
[`ci-cd.md`](ci-cd.md).

`Trivy` is *not* a job either — it is a code-scanning check created by the SARIF upload. It
reports on every pull request only because the filesystem scan uploads from `security.yml`.
If that upload were ever removed, requiring `Trivy` would hang every pull request that skips
the container build.

### Should the DAST scan fail the build?

The ZAP baseline scan runs and reports; `fail_action` is `false`.

**Why it matters:** a scan that cannot fail is a report nobody reads. Until its current
findings are triaged, though, turning it on would block every pull request on the same
pre-existing warnings.

**When:** after triaging what it currently reports.

### SonarCloud or self-hosted SonarQube?

The job is wired and skips itself without a `SONAR_TOKEN`.

**When:** whenever the quality gate is actually wanted. It blocks nothing today.

---

## Deferred by proof-of-concept scope

Not open questions so much as known gaps. Real answers are needed only if this is ever
deployed; they are recorded so the gap is known rather than forgotten. Tracked as N-5.x in
[`REQUIREMENTS.md`](../REQUIREMENTS.md).

- Password reset email has no delivery service — the flow and mailer exist, nothing sends.
- No email verification, so an account can be registered against an address its owner does not
  control.
- `RAILS_FORCE_SSL` and `RAILS_ASSUME_SSL` default to off — see N-3.11.
- No backups, and no restore has ever been tested.
- Multi-environment strategy — staging and production, or production only.
