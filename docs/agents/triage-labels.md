# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column if you adopt different names — `/triage` applies whatever is
on the right, so keeping it accurate is what stops duplicate labels being created.

## Creating the labels

Only `wontfix` exists on the repo today (GitHub's default, described as "This will not be
worked on"); `/triage` will reuse it rather than making a second one. The other four have
never been created, and `gh issue edit --add-label` fails on a label that does not exist
rather than creating it — so run this once before the first triage session:

```bash
gh label create needs-triage    --description "Maintainer needs to evaluate this issue" --color FBCA04
gh label create needs-info      --description "Waiting on reporter for more information" --color D876E3
gh label create ready-for-agent --description "Fully specified, ready for an AFK agent"  --color 0E8A16
gh label create ready-for-human --description "Requires human implementation"            --color 1D76DB
```

The repo also carries GitHub's stock `question`, `duplicate` and `invalid` labels. None of
them carry a triage role here — `needs-info` is the one that means "waiting on the
reporter", not `question`.

## Provenance labels

Two more labels exist, and they are not triage roles — they record where a batch of issues
came from, so that "what did the scanner find" and "what did the review find" remain
answerable months later with `gh issue list --label <name>`:

| Label | Meaning |
| --- | --- |
| `sonarqube` | Filed from a SonarQube scan finding |
| `architecture-review` | Filed from a pass in `docs/architecture-reviews/` |

Both were created on 2026-08-19, along with the four triage labels above, when the first
batches were filed.
