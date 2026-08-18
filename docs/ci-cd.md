# CI/CD

GitHub Actions, in three workflows: `ci.yml` gates pull requests, `security.yml` scans on all
of them, and `release.yml` ships after merge.

## The pipelines

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | Pull requests touching `web/**`, `.github/**` or `sonar-project.properties` | Workflow lint, release-tooling tests, RuboCop, RSpec, container build + image scan + DAST, SonarQube |
| `security.yml` | **Every** pull request | Brakeman, bundler-audit, Trivy filesystem scan |
| `release.yml` | After merge to `main` | Derives the version, builds and publishes the image, tags and releases |

**Why there is no routing.** There was briefly a parent pipeline routing to child pipelines by
changed path, because application and infrastructure code lived in one repository and a
Terraform change had no business running RSpec. Moving infrastructure to
[JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra) removed the decision rather than automating it — and with it the
router, the aggregate gate that existed to avoid required-check deadlock, and the test suite
for the router itself.

Worth remembering as a general point: **a lot of pipeline complexity is a monorepo cost**, not
an inherent one.

## `paths` on the trigger, and what it costs

`ci.yml` is filtered on the trigger rather than per job, so a documentation-only pull request
shows no application checks at all rather than a column of greyed-out skipped ones.

**The catch, before anything is added to a required-checks list.** A job skipped by an `if`
still reports a `skipped` conclusion, which satisfies a requirement. A workflow that is never
*triggered* reports nothing at all — so requiring `Lint` would leave every documentation-only
pull request waiting forever for a status that is never coming. There is no timeout on that
wait.

This repository has already been bitten by the same mechanism once: the `Trivy` check is
created by a SARIF upload rather than being a job, and when the only upload lived in the
container job, documentation pull requests never created the check and GitHub listed it as
expected and waiting. It read exactly like a job refusing to be scheduled.

**So the only check safe to require today is `SAST`**, from `security.yml`, which is
deliberately unfiltered and therefore always present. Requiring anything from `ci.yml` needs
either a change of shape or an always-running aggregate job.

## The release tooling is tested in CI

`ci.yml`'s first job runs [`actionlint`](https://github.com/rhysd/actionlint) over the
workflows — it catches expression injection, invalid `needs:` references and deprecated
syntax, and runs shellcheck over every `run:` block, which is how it found an unquoted command
substitution feeding `SECRET_KEY_BASE` into the container job.

It also runs `test-next-version.sh`, which **had never run in CI at all**. The script deriving
every release version was guarded only by someone remembering to run it by hand — a script
that has shipped a wrong tag twice.

## Bracketed prefixes and the release

With squash merging the pull request title becomes the commit subject, and `next-version.sh`
anchors every Conventional Commit pattern at `^`. A title like `[WIP] feat(feed): …` therefore
matched nothing, `bump=none`, and the release was silently skipped — no tag, no image, exit
code 0.

The script strips leading `[TAG]` markers before classifying, with regression tests covering
single tags, stacked tags, and tagged commits that must *not* release. As ever with this
script, the tests were checked against the unfixed version first: five of the seven failed,
which is the only evidence they test anything.

All work reaches the default branch through a pull request, and a pull request merges only
once these pass. Jobs run in parallel:

| Job | What it does | Fails the build on |
| --- | --- | --- |
| **Lint** | RuboCop with `rubocop-rails-omakase` | any offence |
| **Test** | RSpec on SQLite | any failure |
| **SAST** | Brakeman, bundler-audit, Trivy filesystem scan | any Brakeman warning, any gem CVE, any fixable HIGH/CRITICAL |
| **Container** | Builds the image, Trivy image scan, boots it, OWASP ZAP baseline scan | any fixable HIGH/CRITICAL in the image, or the container failing to serve `/up` |
| **SonarQube** | Quality gate | quality gate failure — skipped while unconfigured |

On the security gates:

- **Trivy fails on HIGH and CRITICAL, in both the filesystem and the image scan.** MEDIUM
  and LOW are reported without blocking. A HIGH in the image is usually inherited from the
  base image rather than written here, but inherited is not the same as acceptable — the
  fix is to bump the base image or patch the package, and the build stays red until someone
  does.
- **Each Trivy scan runs twice: once to gate, once to report.** The gating pass filters to
  HIGH and CRITICAL and sets an exit code; the second pass produces SARIF at every severity
  and uploads it to code scanning. The reporting pass is `if: always()`, so a failing gate
  still publishes what it found — a scan that fails the build without saying why is the less
  useful half of the two.

**A note on the `Trivy` check, because it looks like a job and is not.** It is created by
GitHub code scanning, named after the tool inside the SARIF, and it exists only when something
uploads results. Until recently the only upload was in the container job, which a docs-only
pull request skips — so on those pull requests the check was never created at all, and GitHub
listed it as expected and waiting for a status that was never coming. It reads exactly like a
job that refuses to be scheduled.

The filesystem scan now uploads too, from the SAST job, which is never skipped. That closes
two things at once: the check reports on every pull request, and the filesystem findings —
including the secret scanning that runs on documentation changes — reach the Security tab
instead of only ever setting an exit code.

This matters for required status checks (N-4.2). Requiring `Trivy` before this change would
have deadlocked every documentation pull request permanently.
- **`ignore-unfixed` is on**, so only findings with an available fix count. A vulnerability
  with no upstream patch cannot be actioned by any change in this repository; failing on it
  would only teach everyone to ignore the gate.
- **DAST reports but does not fail.** A baseline scan of a fresh Rails app flags
  header-level warnings (CSP, permissions policy) that are real but out of scope for
  milestone 1. Once triaged, flip `fail_action` to `true` so regressions block.

The container job is also the proof that the image works: it starts the built image and
polls `/up` until the app answers, so a broken image fails CI rather than a deployment.

## `release.yml` — after merge to the default branch

This workflow **ships; it does not re-test.**

1. Derive the next semantic version from the Conventional Commits since the last tag.
2. Stop here if nothing warrants a release.
3. Build the image and push it to the **GitHub Container Registry** at
   `ghcr.io/gauranshmathur/twitter-clone-web`, tagged with the version, `sha-<commit>` and
   `latest`, for both `linux/amd64` and `linux/arm64`.
4. **Then** create the git tag and the GitHub release.

Nothing from `ci.yml` is repeated here. Every check ran on the pull request against this
same code, and running the suite twice spends the same minutes to reach the same answer.
The merged code is built exactly once, by this workflow.

The ordering in steps 3 and 4 is deliberate. These jobs used to run in parallel, so the tag
and release appeared while the build was still going — a pull of the just-announced version
returned `not found` for several minutes, and a failed build would have left a published
release pointing at an image that never existed.

Because there is no gate on `main`, the pull request has to be a real one. Turn on
**Require branches to be up to date before merging**: without it, two branches can each
pass in isolation and still break once merged, and nothing downstream will catch it.

**Registry: GHCR, for now.** It needs no provisioning — the built-in `GITHUB_TOKEN`
authenticates the push, so there is no registry to create and no secret to manage. Amazon
ECR is written into the workflow and commented out; it arrives with the AWS work, at which
point the image can be pushed to both. Enabling it before the repository and the OIDC role
exist only produces red builds.

**Architectures:** release images are published as a manifest list covering `linux/amd64`
and `linux/arm64`, so `docker pull` selects the right variant. Without the arm64 half, a
pull on an Apple Silicon machine fails outright with `no matching manifest for
linux/arm64`, and AWS Graviton instances want arm64 too. The arm64 build runs under QEMU on
GitHub's x86 runners and is noticeably slower; if that becomes a problem the answer is a
native arm64 runner, not dropping the platform.

Pull request builds stay single-architecture. That image is only scanned and booted on the
runner, and paying the emulation cost on every pull request buys no extra signal.

**Image tagging:** every image carries an immutable `sha-<commit>` tag alongside the
semantic version, so a deployment can always be pinned to an exact build.

## Suppressed scan findings, and how they un-suppress themselves

The Trivy image scan fails on HIGH and CRITICAL findings that have a fix available.
Some do not have one *we* can apply: a dependency ships a precompiled binary, an
advisory lands against the toolchain it was built with, and no release of that
dependency yet carries the rebuild. `ignore-unfixed` does not help, because the
upstream language has shipped a patch even though the dependency has not.

Those go in [`.github/trivyignore`](../.github/trivyignore), one line per finding,
each saying why it cannot be actioned here and what would let it be deleted. The bar
is "no fix this repository can apply" — never "this is inconvenient".

Two details make it an exception rather than a hole:

- **The file is not at the repository root.** Trivy auto-loads a root `.trivyignore`
  into every scan, which would filter the SARIF report as well as the gate. Naming it
  explicitly on the gating step suppresses blocking only; every suppressed finding
  still reaches GitHub code scanning.
- **A later step re-runs the same scan with no ignore file and fails when a
  suppressed finding stops appearing.** That absence is the upstream fix arriving.
  The build failing on good news is deliberate — a warning is scrolled past, and the
  remedy is deleting the line and bumping the dependency it names. Nobody has to
  remember to go and look.

## Configuring SonarQube

The SonarQube job checks for a `SONAR_TOKEN` secret and skips the scan when it is absent, so
it does not block pull requests before the server exists. Add `SONAR_TOKEN` (and
`SONAR_HOST_URL` for a self-hosted server) to repository secrets to turn it on. Project
settings live in `sonar-project.properties`.

## Versioning and releases

The project follows [Semantic Versioning 2.0.0](https://semver.org/): `MAJOR.MINOR.PATCH`.

- **MAJOR** — incompatible changes to a public interface or a migration that cannot be
  rolled back cleanly.
- **MINOR** — new functionality, backwards compatible. Most feature milestones land here.
- **PATCH** — backwards-compatible bug fixes.

While the app is pre-release it stays on `0.x.y`, where `0.MINOR.PATCH` signals that the
public interface is not yet stable.

Conventions:

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`). This is what lets the
  version bump and changelog be derived automatically.
- Releases are git tags of the form `v0.3.1`, created by CI rather than by hand.
- Release notes are generated by GitHub from the commits and pull requests in the range.

Releases are automated in `.github/workflows/release.yml`: when a pull request lands on the
default branch, the commit messages since the last tag decide the bump — `feat` gives a
minor, `fix` and `perf` give a patch, `!` or a `BREAKING CHANGE` footer gives a major. A
merge carrying only `docs`, `chore`, `test` or `ci` commits produces no tag and no image.

**Below 1.0, a breaking change bumps the minor rather than declaring 1.0.0.** SemVer clause 9
says that while the major version is zero the public API is not stable and anything may change,
so `0.1.3` plus a breaking change is `0.2.0`, not `1.0.0`. Reaching 1.0 is a deliberate claim
that the app is stable, and should be an act rather than a side effect of a commit footer. The
rule lifts automatically once the project is genuinely at 1.x, where a breaking change gives a
major as normal.

The derivation lives in [`.github/scripts/next-version.sh`](../.github/scripts/next-version.sh)
with tests beside it, run as `.github/scripts/test-next-version.sh`. It is a script rather than
inline YAML because it has shipped a wrong tag twice, and inline it could not be exercised
without pushing:

- **v0.0.1 instead of v0.1.0.** Only the newest commit in the range was ever classified — every
  record after the first began with a newline, so `head -n1` returned an empty subject. Seven
  tests passed against the bug, because every one of them put the release-worthy commit newest.
- **v1.0.0 instead of v0.2.0.** A `BREAKING CHANGE` footer bumped the major with no 0.x case,
  which would have promoted this proof of concept to a stable release.

Both are now regression tests, and new cases are expected to be checked against the unfixed
script first — a test that passes either way proves nothing.

This is why the commit prefix is functional rather than decorative: mislabel a feature as a
chore and it silently never ships a version.

**With squash merging, the squash commit message is the one that counts.** The individual
commits on a branch collapse into a single commit on the default branch, so a branch full of
tidy `feat:` commits still produces no release if the squash title is left as something
generic. Keep the pull request title in Conventional Commit form — it is what GitHub offers
as the default squash subject.

The bump is derived by a short script in the workflow rather than an off-the-shelf action.
The usual candidate, `github-tag-action`, cannot cut a *first* release: with no existing tag
it has no range to diff against, reports "Analysis of 0 commits" and declines to release.
Treating "no tag yet" as "consider the whole history" is the only behavioural difference.
