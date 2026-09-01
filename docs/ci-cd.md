# CI/CD

GitHub Actions, in three workflows: `ci.yml` gates pull requests, `security.yml` scans on all
of them, and `release.yml` ships after merge.

## The pipelines

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | Pull requests, and merges to `main`, touching `web/**`, `.github/**` or `sonar-project.properties` | Workflow lint, release-tooling tests, RuboCop, RSpec, container build + image scan + DAST (pull requests only), SonarQube |
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
| **SonarQube** | Bugs, vulnerabilities, smells, duplication and coverage, published to SonarQube Cloud | nothing yet — the scan reports, the quality gate does not block. See [SonarQube](#sonarqube) |

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

## Suppressed scan findings, and how they un-suppressed themselves

The Trivy image scan fails on HIGH and CRITICAL findings that have a fix available.
**There are no suppressions today**, and the story of the ones there were is the point
of this section.

Some findings have no fix *this repository* can apply: a dependency ships a precompiled
binary, an advisory lands against the toolchain it was built with, and no release of that
dependency yet carries the rebuild. `ignore-unfixed` does not help, because the upstream
language shipped a patch even though the dependency has not. Eight such findings — all
Go advisories inside the binary the [thruster](https://github.com/basecamp/thruster) gem
ships — lived in `.github/trivyignore`, one line each, saying why it could not be
actioned here and what would let it be deleted. The bar was "no fix this repository can
apply", never "this is inconvenient".

Two details made it an exception rather than a hole:

- **The file was not at the repository root.** Trivy auto-loads a root `.trivyignore`
  into every scan, which would have filtered the SARIF report as well as the gate. Naming
  it explicitly on the gating step suppressed blocking only; every suppressed finding
  still reached GitHub code scanning.
- **A second step re-ran the same scan with no ignore file and failed when a suppressed
  finding stopped appearing.** That absence is the upstream fix arriving. Failing the
  build on good news is deliberate: a warning gets scrolled past, and the remedy is
  deleting a line and bumping the dependency it names.

**It worked, which is why the file is gone.** thruster 0.1.26 was rebuilt on a patched Go
toolchain: measured against the binary each version ships, 0.1.25 carried nine fixable
HIGH/CRITICAL findings and 0.1.26 carries none. Bumping the gem cleared all eight
suppressions at once, so the file, the `trivyignores:` line and the stale-entry detector
were deleted together.

If a suppression is ever needed again, bring the whole shape back — the explicitly named
file *and* the detector that watches it. A suppression with nothing watching it is how a
temporary exception becomes permanent.

## SonarQube

The target is **SonarQube Cloud** (`https://sonarcloud.io`), organization `gauranshmathur`,
project `GauranshMathur_JDSG-Group6-app`. Settings live in `sonar-project.properties`; the
scan runs in `ci.yml`'s `sonarqube` job, authenticated by the `SONAR_TOKEN` repository
secret.

**It reported a green check for weeks without ever scanning anything.** Three things were
wrong at once, and the first hid the other two:

1. The job skipped itself unless `SONAR_TOKEN` was set, and printed a notice nobody reads.
   A scan that quietly does nothing is indistinguishable, on the pull request, from one
   that passed. **The guard is gone**: a missing token now fails the job.
2. `sonar.projectKey` was hand-written (`jdsg-group6-twitter-clone`) and there was no
   `sonar.organization` at all. Both keys are assigned by SonarQube Cloud at import and are
   not free-form, so the scan would have failed on its first real run. Read them back from
   the API rather than retyping them:
   `curl -s "https://sonarcloud.io/api/components/show?component=GauranshMathur_JDSG-Group6-app"`
3. `SONAR_HOST_URL` was read from a secret that was never created. It is now a literal in
   the workflow — it is the same public endpoint for every project, so keeping it in a
   secret bought nothing and is exactly how it ended up unset.

**Automatic Analysis must stay off.** SonarQube Cloud offers a zero-configuration analysis
that runs on its own servers on every push, and it is enabled by default when a repository
is imported — it is what produced this project's first analysis. It is **mutually exclusive
with CI-based analysis**: with both on, the CI scan fails with *"You are running CI analysis
while Automatic Analysis is enabled."* CI analysis is the one worth keeping, because it is
the only one that can import coverage. The toggle is
*Administration → Analysis Method → Automatic Analysis*, and its state is readable without
logging in:

```bash
curl -s "https://sonarcloud.io/api/settings/values?component=GauranshMathur_JDSG-Group6-app" \
  | grep -o 'sonar.autoscan.enabled[^}]*'
```

**`main` is analysed too, which is why `ci.yml` now has a `push` trigger.** A pull request
analysis is measured against the target branch's analysis; with nothing ever analysing
`main`, there is no baseline to measure against and the dashboard freezes at whatever ran
last. Automatic Analysis used to cover this, and turning it off removed it — a hole worth
naming, because it opens silently and every check stays green while it does. The container
build, image scan and DAST stay pull-request-only: `release.yml` builds and publishes the
same image on merge, so running them again would spend five minutes twice on one commit.

**What Sonar looks at, and what it does not.** `sonar.sources` is `web/app`, `web/lib` and
`web/config` — application code, including the ERB templates. Workflow files, the Dockerfile
and the Compose files are deliberately outside it: Trivy's config scan and `actionlint`
already cover those, and they cover them on *every* pull request rather than only the ones
touching `web/**`. The division is that Sonar reads the application and the security
workflow reads the plumbing.

**Coverage comes from the suite, not from a second run.** `spec/spec_helper.rb` starts
SimpleCov before anything else loads and writes `web/coverage/coverage.json`; the Test job
uploads it as an artifact and the SonarQube job downloads it. SimpleCov JSON is the only
coverage format Sonar's Ruby analyser reads — **it does not accept LCOV**, which is the
obvious wrong turn to take here. The paths inside the report are absolute, which works only
because every job in a workflow checks out to the same path on the runner.

**The quality gate reports; it does not yet block.** The scan publishes to the dashboard and
the job passes regardless of the gate's verdict. Making the gate blocking is a separate
decision, and a fair one to take once there is a clean baseline to hold the line at —
`-Dsonar.qualitygate.wait=true` is the switch.

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
