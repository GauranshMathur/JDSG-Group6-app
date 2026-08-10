# Architecture decision records

A record per decision that had a real alternative and a cost worth remembering. The point is
not to document everything — it is so that "why is it like this?" has an answer six months
later, including the answer "we knew, and here is what we accepted".

A decision with no genuine alternative does not need a record. It is a line in whichever
document it affects.

## Format

Context, then the decision, then the consequences — good *and* bad. An ADR that lists only
benefits is marketing, not a record. If a choice cost nothing, it probably was not a decision.

Records are immutable once accepted. When one is overturned, the new record supersedes it and
the old one stays, marked. The reasoning that turned out to be wrong is usually the most
useful part.

## Records

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-authentication.md) | Authentication with the Rails 8 generator, not Devise | Accepted |
| [0002](0002-keyset-pagination.md) | Keyset pagination for the timeline, not offset | Accepted |
| [0003](0003-sqlite-first.md) | SQLite first, PostgreSQL later, switchable by env var | Accepted |
| [0004](0004-hashtags-and-search.md) | Hashtags via a join table; search via `LIKE` | Accepted |
| [0005](0005-posts-outlive-accounts.md) | Posts outlive their author's account; identities are never reused | Accepted |
| [0006](0006-immutable-usernames.md) | Usernames are chosen at registration and never change | Superseded by [0007](0007-changeable-usernames.md) |
| [0007](0007-changeable-usernames.md) | Usernames are changeable; uniqueness is the only guarantee | Accepted |
| [0008](0008-k6-load-generation.md) | k6 generates the stress-test load | Accepted |
| [0009](0009-opentelemetry.md) | Telemetry is OpenTelemetry, not hand-rolled log lines | Accepted |

Records about infrastructure live in
[JDSG-Group6-infra](https://github.com/GauranshMathur/JDSG-Group6-infra/tree/main/docs/adr). ADR 0008 — Terraform is verified against the
emulator, the app is deployed on a real local cluster — moved there when the repositories
split, and is numbered 0001 in that repository's own series. Immutability applies to a
record's content once accepted, not to which repository it lives in.
