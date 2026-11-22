# Recovery

Every mutating operation runs through a journaled transaction: protected
intent, staging, quarantine, independent backups, and per-scope coordination.
If a mutation is interrupted, its retained evidence can be inspected and
driven to a safe terminal state.

## Ordinary resource recovery

```text
agent-resource skill recover [<transaction-id>] [--action rollback|complete]
agent-resource agent recover [<transaction-id>] [--action rollback|complete]
agent-resource mcp recover [<transaction-id>] [--action rollback|complete]
```

Recovery validates the target and retained evidence before making a change.
It refuses changed targets, unverified quarantine or staging bytes, and
other ambiguous states rather than overwriting or removing them. Without a
transaction ID it lists the pending transactions it can act on. Recovery
cannot overwrite new occupants, erase newer edits, or guess an interrupted
outcome — foreign content is retained and reported.

Interrupted **configuration publications** are inspected through the same
commands by selecting the exact configuration target:

```text
agent-resource skill recover --configuration-target <path> --scope all
agent-resource agent recover <transaction-id> --configuration-target <path> --action rollback --dry-run
agent-resource agent recover <transaction-id> --configuration-target <path> --action rollback --yes
```

Supply the same `--cwd` and `--project-root` used for the original
publication when inspecting older project-scoped evidence. Older project
evidence cannot be discovered from a different project, and older
transactions did not record their staging directory. Stop other writers
while recovering; there is no machine-wide lifecycle lock.

## Coordinated Prompt conversion transactions

```text
agent-resource prompt conversion list [--scope project|user|all]
agent-resource prompt conversion inspect <transaction-id> --scope project
agent-resource prompt conversion recover <transaction-id> --scope project
agent-resource prompt conversion cleanup <transaction-id> --scope project
```

These use retained coordinator evidence, not editor drafts or managed-only
backups. Inspection and default recover/cleanup are read-only; apply
requires `--apply --yes --plan-id <reviewed-plan-id>` where the plan ID is
the current review identity. The protected commit decision fixes the
direction: rollback before commit, completion after commit. No
caller-selected override, force, or rebaseline is provided. A pending
conversion reserves its participants — paths, identities, and pack
membership — and ordinary mutations of reserved resources refuse, naming
the blocking transaction, in both scopes.

## Authoring transactions

```text
agent-resource authoring list [--scope project|user|all]
agent-resource authoring inspect <transaction-id> --scope project
agent-resource authoring recover <transaction-id> --scope project
agent-resource authoring cleanup <transaction-id> --scope project
```

The same review-identity contract applies. A publication before commit can
be rolled back (removing the published target and restoring the reviewed
source); a committed publication can only be completed. Cleanup deletes only
the verified terminal private payload and keeps the evidence document as the
audit record; the review explicitly discloses loss of payload-based restore.
No recovery path deletes an editing draft or a user input file.

## Boundaries

This is local filesystem recovery, not native harness verification and not a
guarantee of power-loss durability or secure erasure. Evidence anchored to a
scope cannot be discovered from unrelated roots; coordinate writers
externally when they can affect the same resources across unrelated roots.
