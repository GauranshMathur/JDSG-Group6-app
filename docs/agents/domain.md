# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This is a **single-context** repo: one app in `web/`, one set of decision records in
`docs/adr/`.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the glossary. It does not exist yet; see below.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in. Eleven exist
  today, indexed by [`docs/adr/README.md`](../adr/README.md).

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md          ← not yet written; created lazily by /domain-modeling
├── docs/adr/
│   ├── 0001-authentication.md
│   ├── …
│   └── 0011-ranked-window.md
└── web/                ← the Rails app; internal paths are web/app/, web/spec/
```

Note the app lives under `web/`, not at the root — a path like `app/models/post.rb` is
wrong here.

## Where the rest of the project's prose lives

Domain docs are not the only written record. `CLAUDE.md`'s "Where things are written
down" table is the canonical index of the rest — requirements, roadmap, design
principles, open questions — and it is loaded every session. Read it there rather than
duplicating it here, and don't restate in an issue or a proposal what one of those files
already records.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Writing an ADR here

An ADR is for a decision with a real alternative and a cost worth remembering; a decision
with no genuine alternative is just a line in the document it affects. **An ADR that lists
only benefits is marketing — record what the choice cost.**

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts [ADR 0011](../adr/0011-ranked-window.md) (ranked window) — but worth reopening because…_
