# Pack command migration

## Public model

`skill` and `agent` describe resource inspection, validation and authoring.
`pack` describes installation and managed lifecycle operations over a collection.
A pack may offer multiple resource types; selecting one type must not imply
installation or mutation of the others. A standalone resource is conceptually a
one-member collection, without a requirement to author a repository first.

Native formats remain native. Agent definitions are standalone Markdown or TOML
files, validated against their applicable harness profiles, not per-agent bundles.
Prompts are a future resource type, not an implemented format inferred by this spec.

## Selection contract

Canonical syntax is `pack <operation> <pack> --type skill|agent`, with repeatable
`--type` for multiple resource types. `--only` narrows resource selection further.
Neither selector silently changes persistent installation membership. A name that
matches multiple types needs an unambiguous typed selection.

Type selection applies to install, update, remove, rollback, cleanup, validation,
and source operations. Commands must reject unsupported combinations before effects,
not silently ignore them. A pack-wide source or tracking change cannot masquerade
as a type-scoped change while altering other installed resource types.

## Source discovery

Default discovery roots are `skills/` and `agents/`, relative to the acquired source
boundary. A pack may configure alternate safe relative directories:

```toml
schema_version = 1

[packs."owner/repository".discovery]
skills_directory = "resources/skills"
agents_directory = "resources/agents"
```

Explicit source catalogs remain authoritative. Folder discovery must stay bounded
and reject unsafe paths and symlinks rather than following arbitrary source trees.
A supported filename or folder is only a candidate; normal validation still applies.
Discovered Agents have no inferred native profile: authors must select them through
an explicit catalog entry with `profile = "claude"`, `"codex"`, or `"pi-common"`.

## Read-only pack validation

`pack validate <pack>` acquires an inert source view and validates selected source
resources without requiring `--scope` or `--yes`. Canonical invocation defaults to
both resource types; `--type` isolates catalog parsing and validation, and `--only`
selects unambiguous native names. Configured exclusions apply unless `--only`
explicitly selects a resource. Validation never installs, converts, or executes
content and never creates or advances installation locks, journals, backups,
selection/membership history, consent, or configuration state. Acquisition
workspaces are cleaned after success and failure. `--dry-run` is accepted as an
explicit restatement of the always-read-only behavior; mutation-only options are
rejected before acquisition rather than ignored.

Successful results use operation `pack.validate`, outcome `valid`, and per-resource
`validated` dispositions. Independent native diagnostics are aggregated into safe
code/field messages without instruction bodies. Invalid input and native validation
failures exit 2 with no success envelope; acquisition and cleanup failures retain
their operational nonzero statuses. These checks establish source-format validity
only, not runtime discovery, release qualification, or harness execution readiness.

## Update membership and additions

Updates affect active managed installations by default. `--yes` approves a plan;
it is not permission to expand installed membership.

An interactive update may offer to review additions, defaulting to No. Individual
additions require explicit selection, with nothing preselected. The final plan
separately lists updates and new installations and warns about membership expansion.
`--skip-new` suppresses review. In unattended execution `--include-new` explicitly
allows eligible additions; it conflicts with `--skip-new`.

Addition detection compares source-relative discovery identities against the last
successfully reviewed inventory for the pack and resource type:

- Skills: resource folder paths.
- Agents: supported native definition file paths within the agents directory.

Existing but previously skipped paths are not new. Editing contents at an existing
path is not a new resource. Arbitrary folders are not additions. Explicit exclusions
remain excluded, and previously removed resources must not be silently resurrected.
Renames can appear as new paths; that never authorizes deleting the old installation.

The inventory records reviewed discoveries, including declined additions, separately
from installed-version/baseline state. Advance it only after successful approval and
completion, not during planning, dry-run, cancellation, or failure. A skill-only review
does not advance an agent inventory. No-save operation semantics must remain explicit.

Legacy installations lacking an inventory require explicit baseline establishment,
not a claim that all currently uninstalled resources were newly published. Changing
discovery directories requires explicit reconciliation, not mass "new" detection.

## Migration safety

Preserve installation IDs, native paths, ownership, baselines, retained snapshots,
backups, and recovery records. Do not reinstall resources merely to rename commands.
Filtered updates must not advance version evidence for untouched installations.

Introduce canonical `pack` entry points before retiring existing paths. During a
compatibility window, plural paths map to their corresponding fixed resource type:

- `skills update <pack>` → `pack update <pack> --type skill`.
- `agents update <pack>` → `pack update <pack> --type agent`.

Apply the same principle to other existing plural lifecycle operations. Singular
lifecycle paths have different source/input contracts and need dedicated adapters;
a blind token substitution is not a safe migration. Keep their behavior until such
adapters exist. Deprecation notices belong on stderr, never in JSON stdout.

## Acceptance scenarios

- Updating two installed skills never implicitly installs skipped skills or agents.
- A newly added valid skill folder is offered once; declining it after an approved,
  successful update means it is known on the next review.
- A newly added agent Markdown or TOML file is eligible even if its parent agents
  directory was already known.
- Existing source paths with changed contents are updates only when installed.
- Failed, cancelled and dry-run operations do not consume additions.
- Type filtering isolates changes and review inventories across mixed packs.
- A discovery-directory change cannot silently authorize a mass installation.
- Native safety, ownership, drift, snapshot and recovery checks remain in force.
