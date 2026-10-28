# Migrate an existing installation to interactive installation

Use this guide when an existing managed Skill copy/link or native Agent file
should be reinstalled through the current `skill install` or `agent install`
contract. This is a deliberate removal followed by a fresh installation, not
an upgrade or conversion operation.

The installer does not infer an origin for an old record, promote an old shared
copy to canonical ownership, relocate content, or automatically convert legacy
copy/link records. Equal names or content hashes do not prove that an old
installation and a new source have the same origin. Existing old artifacts
remain manageable under their recorded semantics; migrate only when the fresh
source and intended ownership method are explicit.

## 1. Stop if the source or ownership evidence is unavailable

Identify the exact source to install and independently confirm that it is still
available and appropriate. A direct Agent file needs its native profile
(`claude`, `codex`, or `pi-common`); a Skill needs its intended method
(`canonical`, `copy`, or `source-link`) and consumers.

Inspect and verify the old installation in its actual scope before changing it.
For example:

```text
agent_resource skill list --scope user --verify --format json
agent_resource skill backup list --scope user --format json

agent_resource agent list --scope project --verify --format json
agent_resource agent backup list --scope project --format json
```

Use the returned managed installation ID and location, not an inventory
occurrence ID. `--verify` checks the current artifact against its recorded
baseline. Backup listing checks retained backup integrity and records the
backup IDs available for recovery. Retain adequate backups and any transaction
evidence; do not run backup cleanup as part of migration preparation.

**Stop if the source is missing, the record cannot be read or verified, or
required backup/recovery evidence is unavailable or ambiguous. Do not erase
the only usable copy in an attempt to proceed.** Resolve the evidence problem
or restore a verified backup first.

For an old source-linked Skill, removal owns only the link entry. It never
deletes the external source-link target. Do not manually delete that target as
part of migration; it may be the only source and may have other consumers.

## 2. Preserve state and respect version refusal

Before changing application versions, retain an independent copy of the
selected management state directory and its retained backups in addition to
the application's normal backup records. Keep this evidence until the fresh
installation and its recovery position have been verified.

Supported old records are read with their original identity and ownership
meaning; they are not bulk rewritten. Unknown or incompatible management,
record, backup, or transaction schema versions are refused rather than reset
or discarded. An older writer/downgrade is not a supported way to operate on
state written with newer capabilities. Do not run old and new writers
concurrently against the same state. If a version refusal occurs, stop, retain
the state and backups, and use a compatible application version and its
recovery procedure rather than deleting or hand-editing the ledger.

## 3. Deliberately remove the old installation

Review removal with `--dry-run`, then remove the exact old managed installation
with explicit approval. For example:

```text
agent_resource skill remove <installation-id> --scope user --dry-run
agent_resource skill remove <installation-id> --scope user --yes

agent_resource agent remove <installation-id> --scope project --dry-run
agent_resource agent remove <installation-id> --scope project --yes
```

Alternatively, use the lifecycle commands' explicit `--interactive` review.
Removal requires the old artifact to match its complete unchanged baseline and
creates a retained backup before live mutation. Record the reported backup ID.
Do not clean that backup before the replacement is known to be sound.

These commands remove the whole old installation. The canonical-only exposure
selector described below is not a legacy copy/link migration mechanism.

## 4. Fresh-install from the explicit source

The following unattended examples show all choices that the current installer
does not infer outside interactive use:

```text
agent_resource skill install <source> --source-kind resource --target claude --target codex --scope user --method canonical --yes

agent_resource agent install <native-file> --source-kind resource --profile claude --target claude --scope project --yes
```

Use `--source-kind collection` with repeated `--resource <catalog-id>` or
`--all-resources` for a curated collection instead. A direct Agent file
requires one target consistent with its profile. Add `--format json` for the
schema-version-2 success envelope; JSON remains unattended and requires the
same explicit choices. Omit `--yes` only for `--dry-run`. On a usable text
terminal, the default interactive workflow can instead collect the source and
selections and review the final plan.

The retired install options `--destination`, `--harness`, `--mode`, and
`--interactive`, and Agent `--output`, must not be carried into the fresh
command. Skill installation now uses `--target` and `--method`; direct Agent
installation uses `--profile` and `--target`. Agent installation always
creates a native file copy and preserves the validated source basename.

## 5. Understand the interruption gap and verify the result

Removal and fresh installation are separate operations. **The sequence is not
atomic.** Interruption or failure after removal but before or during fresh
installation can leave no live replacement, only part of a requested batch, or
recovery evidence requiring attention. Fresh installation can independently
fail validation, acquisition, preflight, ownership/conflict checks, approval,
publication, or required cleanup. A successful old removal does not guarantee
that the new source can be installed.

After any interruption, inspect the actual filesystem and management records;
do not assume either rollback or completion. Use the reported transaction and
backup IDs with the applicable `recover` or `backup restore` command, following
its reviewed recovery guidance. Recovery establishes a guarded state; it does
not retroactively make the whole migration atomic.

After successful installation, run the scoped inventory with `--verify` and
confirm every expected canonical content entry, exposure/copy/link, native
Agent copy, installation ID, and consumer relationship. Retain the old backup
until this verification is complete.

## Canonical exposure detach is not migration

For an existing canonical Skill, this command detaches only its managed Claude
exposure link and retains the canonical content:

```text
agent_resource skill remove <installation-id> --target claude --scope user --yes
```

Codex consumes canonical content directly from scope-specific `.agents/skills`.
There is no direct-Codex detach equivalent: removing consumer metadata cannot
make shared canonical content undiscoverable. To revoke Codex access, review
and perform whole canonical removal instead, accounting for every associated
consumer. Do not apply `--target` to legacy copy/link artifacts.
