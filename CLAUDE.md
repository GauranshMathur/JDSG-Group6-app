# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

A Twitter/X-style social application, built with Ruby on Rails.

**It is a proof of concept.** Nothing is deployed and nothing holds real data. Where a
decision trades production robustness for something working and understandable, take the
second — and say so at the point you take it, rather than leaving it to be discovered.
Gaps that only matter once deployed go in the "Deferred by proof-of-concept scope" table in
`REQUIREMENTS.md` instead of quietly not existing.

This does not license sloppiness in the things the project is actually exercising: the tests,
the CI gates and the security scanning stay as they are.

Where things are written down:

| File | What it holds |
| --- | --- |
| `README.md` | What the project is and how to run it. Keep it short — prose belongs in `docs/` |
| `REQUIREMENTS.md` | Numbered requirements and whether each is met. Update the status when a requirement's state actually changes |
| `docs/roadmap.md` | Milestones, what shipped, and the plan for the next ones |
| `docs/design-principles.md` | The 90-9-1 rule, and ownership over visibility |
| `docs/database.md`, `docs/ci-cd.md` | The detail for each |
| `docs/latency.md` | How the app should degrade when the database is slow. The query-count guard is built; the rest is planned — see N-6.x |
| `docs/open-questions.md` | Decisions not yet taken, each with why it matters and when it is needed |
| `docs/adr/` | Decision records — why a choice was made, and what it cost |

**Current state: milestones 1–7 done (including 5.5 and 6.5).** The Rails app exists in
`web/`, the feed works, and accounts exist — register, sign in, sign out, reset. Posts belong
to their authors, who can edit and delete their own. Every account has a unique, changeable username,
a public `/@username` profile page, and an editable display name, bio, and avatar; a sidebar
is the application shell. Engagement is complete: likes, reposts, replies (with a post detail
page), and hashtags (parsed, linked, with tag pages). The feed ranks the last week by
engagement and continues into everything older, newest first
([ADR 0011](docs/adr/0011-ranked-window.md)); the ordering is cached. Search finds posts by
body text and users by username via plain LIKE. Profile avatars
and post images are supported via Active Storage with WebP conversion and EXIF stripping.
No follows, no jobs, no infra.

## How we work here

The project is built **incrementally, one vertical slice at a time**. This matters more than
any individual convention below:

- Do not scaffold ahead of the current milestone. If milestone 1 is the feed, do not add
  a follow graph, likes, or auth "while we're in there".
- **Each milestone is built, tested, and merged before the next one starts.** A milestone
  is not done until its PR is green and merged into the default branch. Each milestone gets
  its own branch and its own pull request — do not stack milestones on a single branch or
  start the next milestone on unmerged work.
- Prefer finishing one feature end-to-end — **specs first** (red), then
  migration → model → controller → view (green), then refactor — over starting several.
- When a decision is genuinely open, ask rather than guessing. Add it to
  `docs/open-questions.md` with why it matters and when it needs answering.
- A decision with a real alternative and a cost worth remembering gets an ADR in `docs/adr/`.
  One with no genuine alternative is just a line in the document it affects. An ADR that
  lists only benefits is marketing — record what the choice cost.
- `docs/open-questions.md` is a live list, not an append-only log. When work answers a
  question, delete it and move the answer into the document it belongs to.

## Repository layout

```
web/       Rails application — all app code
docs/      Everything that is not code — roadmap, decisions, open questions
.github/   CI/CD workflows
```

Infrastructure is a separate repository: [JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra).

Rules:

- Application code goes in `web/`. Never at the repository root.
- The Rails app lives at `web/`, so internal paths are `web/app/models/`, `web/config/`,
  `web/spec/`. Watch for this — a path like `app/models/post.rb` is wrong here.
- Infrastructure and deployment code does not belong in this repository at all, with the
  exception of `web/Dockerfile`, which stays next to the app it builds.
- Folder names: lowercase, hyphenated.

## Stack (decided)

- Ruby on Rails 8, full-stack, **not** API-only.
- Hotwire — Turbo and Stimulus. No React/Vue/SPA. Reach for a Turbo Frame or Stream before
  reaching for JavaScript.
- SQLite for now, PostgreSQL later. Nothing may depend on adapter-specific behaviour —
  the switch is meant to stay a single environment variable.
- Sidekiq with Redis for background jobs — decided but **not installed**. Do not add either
  until a milestone actually needs a job.
- OpenTelemetry for telemetry — **installed** in milestone 8 slice B
  ([ADR 0009](docs/adr/0009-opentelemetry.md)). The exporter is configuration:
  `OTEL_TRACES_EXPORTER=console` or `otlp`, unset means nothing is emitted.
- k6 for load generation — **in use** since milestone 8 slice C
  ([ADR 0008](docs/adr/0008-k6-load-generation.md)). Scenarios live in
  `web/script/stress/`, driven by `script/stress-test`; the k6 binary is a local
  install, not bundled with the app.
- RSpec + FactoryBot for tests. Not Minitest.
- RuboCop with `rubocop-rails-omakase`.
- Propshaft + importmap. No Node build step, no bundler/webpack.

Do not introduce a new framework, database, job runner, or test library without asking.

## Conventions

**Ruby / Rails**

- Follow Rails conventions and idioms; prefer boring, conventional Rails over cleverness.
- Fat models are fine to a point — extract to a plain-old-Ruby service object in
  `web/app/services/` when a model method grows past its responsibility.
- Every schema change is a migration. Never edit `db/schema.rb` by hand.
- Add database indexes for foreign keys and any column used for timeline ordering.
- Use strong parameters, and scope queries through associations rather than
  `Model.find(params[:id])` on user-owned records.

**Views**

- ERB, not Haml or Slim.
- Extract repeated markup to partials early — the feed will render the same post markup in
  several places.
- Use Turbo Streams for anything that updates in place.

**Testing — TDD (red-green-refactor)**

Development follows test-driven development. The cycle is:

1. **Red** — write a failing spec that describes the behaviour you want. Tag it with the
   requirement ID from `REQUIREMENTS.md` so every requirement is traceable to at least one
   spec. Commit.
2. **Green** — write the minimum code to make the spec pass. Commit.
3. **Refactor** — clean up while the specs stay green. Commit if anything changed.

Do not write implementation first and tests second. A spec that was green the moment it was
written has never proven anything.

- Model specs for validations, scopes and associations; request specs for controller
  behaviour, authorization and HTTP semantics.
- Every requirement ID in `REQUIREMENTS.md` must be traceable to at least one spec — either
  by a comment (`# F-3.4`) or by describing the requirement in the spec name.
- Every feature slice ships with specs. A PR that adds behaviour with no test is incomplete.
- No system/browser specs until there is enough UI to justify the maintenance cost.
- Run `bundle exec rspec` locally before pushing. CI failing on something a local run
  would have caught wastes a pipeline.

**Commits**

- [Conventional Commits](https://www.conventionalcommits.org/) — the semantic version bump
  is derived from these, so the prefix is functional, not decorative.
- Format: `type(scope): subject`, e.g. `feat(feed): add cursor pagination to timeline`.
- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`.
- **`feat` means a wholly new capability that did not exist before.** A UX improvement,
  behavioral tweak, or polish to something that already works is a `fix`, not a `feat`.
  When in doubt: if removing it would leave a gap in functionality, it was a `feat`;
  if removing it would just revert to the previous behavior, it was a `fix`.
- Breaking changes: `feat!:` or a `BREAKING CHANGE:` footer.
- Subject in the imperative mood, lowercase, no trailing period.

**Branches and pull requests**

- All work reaches the default branch through a **pull request**. Do not commit to it
  directly.
- **One branch per milestone.** Create a fresh branch from `main` for each milestone.
  Do not reuse a milestone's branch for the next milestone.
- Branch names: `feat/<short-description>`, `fix/<short-description>`, `docs/<...>`.
  The branch name must match the commit type — a branch carrying a fix is `fix/...`, not
  `feat/...`. **Never use an environment-assigned branch name** (e.g. `claude/repo-review-*`)
  — always create a properly named branch from `main` instead. If the environment provides a
  branch name, ignore it and create your own following this convention.
- **CI is filtered by path on the trigger** — `ci.yml` runs for `web/**` and `.github/**`, so
  a documentation-only pull request runs no application checks. `security.yml` runs on every
  pull request regardless. See [`docs/ci-cd.md`](docs/ci-cd.md).
- CI is the review gate: a pull request is ready when the pipeline is green, so never open
  one expecting to fix it up afterwards.
- Auto-merge is enabled on the repository but **does not currently gate anything** — `main`
  has no required status checks, so GitHub treats every pull request as immediately
  mergeable and refuses to arm it. Merges are manual until a branch ruleset exists. Do not
  merge on a red or still-running pipeline just because GitHub allows it.
- Run `bundle exec rspec` and `bundle exec rubocop` locally before pushing. CI failing on
  something a local run would have caught wastes a full pipeline.
- Prefer several small, self-contained commits over one large one.

**Run it before you push it.** Green specs are not evidence that the app works. Every bug
that has reached `main` so far passed the suite first: `assume_ssl` returned 422 on every
POST while GETs stayed healthy; a cursor with an unparseable timestamp rendered an empty feed;
the sign-out control shipped unstyled because a spec asserting `response.body` includes a
string cannot see CSS. So for any change that touches a request path or a view:

```bash
cd web && bin/rails server                # then actually load the page
script/smoke-test http://localhost:3000   # register, post, upload an image, read back, sign out
```

`script/smoke-test` is the same script CI runs, so a CI failure is reproducible in one
command rather than by pushing again. When a change is visual, take a screenshot and put it
in the pull request — describing a layout is not the same as looking at it.

## Commands

```bash
# From web/
bin/rails server             # Run the app on http://localhost:3000
bundle exec rspec            # Run all tests
bundle exec rspec spec/path  # Run one spec file
bundle exec rubocop          # Lint
bundle exec rubocop -a       # Lint and autocorrect
bundle exec brakeman         # Security static analysis
bin/rails db:migrate         # Apply migrations
bin/rails db:seed            # Sample posts for the feed
bin/rails console            # REPL
script/smoke-test            # End-to-end checks over HTTP against localhost:3000

# From repo root
docker build -t twitter-clone-web web   # Build the image
```

## Current milestone

**Milestones 8 through 8.7 are built and merged.** Milestone 8 measured and fixed
nothing by design; 8.5 rebuilt the harness as open-model k6 profiles — smoke, load,
breakpoint, spike, 90-9-1 journey mix, error-rate gates, a production-shape target,
Grafana Cloud as the reading surface. What the better instruments found was then fixed
in three measured steps: the ordering cached as identifiers (N-6.8), one rebuild at a
time plus the app's own 404 (8.6, F-8.6.x), and the ranked window (8.7,
[ADR 0011](docs/adr/0011-ranked-window.md)) — the feed ranks the last seven days and
continues chronologically into the archive, so its cost tracks weekly activity rather
than the size of the database. Measured at the 10k seed: warm page 6 ms, load-profile
latencies roughly halved with nothing over a second, and the remaining ceiling is Puma
threads, not the feed. Numbers in [`docs/stress-testing.md`](docs/stress-testing.md).

**What is next, in order:** the repost-duplication decision — the top of the feed
holds few distinct posts because every repost is an independent entry; a product call
recorded in [`docs/open-questions.md`](docs/open-questions.md) — then re-measuring and
judging [ADR 0010](docs/adr/0010-stored-rank-score.md) (stored rank score, still
Proposed) against those numbers. Outstanding from 8.5: the 100k seed run (F-8.3), the
profiles against the production-shape image, and the user-run Tempo round-trip
(F-8.5.5). New app *features* remain a scope expansion to raise with the user, not a
default.

**Infrastructure lives in its own repository.** [JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra) holds the AWS
reference design, the Terraform, the Kubernetes manifests and the decisions behind them. This
repository does not describe its own deployment; the one thing crossing the boundary is the
container image, released here to GHCR and pulled there by the cluster.

**Three app changes are owed to that work**, recorded in the infrastructure repository's
design doc and made **here**, when they block, not before:

- **SQLite → PostgreSQL.** The switch is `DATABASE_URL` by design but has never been proven —
  no CI job has ever run the suite against PostgreSQL.
- **Per-process cache → shared cache.** The ranked-feed cache and the sign-in rate limiter
  live in `Rails.cache` memory. Two replicas means two divergent feeds and a rate limit that
  counts half.
- **Disk → S3 for Active Storage.** Pod filesystems are ephemeral; a redeploy deletes every
  avatar.

Do not write Terraform, Compose files or Kubernetes manifests here. If a task needs them, it
belongs in the other repository, and the two land as separate pull requests.

Anything outside the current milestone — follows, notifications, account deletion — is later.
If a task seems to require one of them, say so and ask rather than expanding scope.

Two rules that carry forward:

- **Reading is public; only writing needs an account.** See `docs/design-principles.md`. Guard `create`, `update` and `destroy` — never `index` or `show`.
- **Authorise by scoping, not by checking.** `Current.user.posts.find(params[:id])`, not
  `Post.find(params[:id])` followed by an ownership comparison. A forgotten comparison
  exposes another user's row; a scope that finds nothing raises.

## Things to leave alone

- Releases publish to GHCR. Do not uncomment the ECR block in
  `.github/workflows/release.yml` until the ECR repository and the GitHub OIDC role
  actually exist.
- Do not add authentication as a side effect of another feature.
- Do not add Redis, Sidekiq, or a background job until a milestone needs one.
- Do not upgrade Ruby or Rails major versions without asking.
- Do not weaken a CI security gate to make a build pass. If a finding is genuinely not
  actionable, say so and ask.
