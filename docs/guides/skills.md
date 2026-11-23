# Skills

Skills are `SKILL.md` packages managed per scope and per harness target.
This guide covers the complete Skill lifecycle; `agent-resource skill --help`
lists the registered surface, and `agent-resource support` reports the
lifecycle boundary contract.

## Inventory

```text
agent-resource skill list [--scope user|project|all]
```

Skill destinations are `.claude/skills`, `.codex/skills`, and
`.agents/skills`. Inventory distinguishes unmanaged candidates, managed
installations, tracked-missing records, and ownership-unverified evidence.
`--verify` performs a fresh baseline comparison; without it, modification is
`notVerified`. Direct ordinary children are eligible for copy adoption;
nested discoveries remain visible but ineligible. Linked candidates are
reported without reading their targets.

Inventory is bounded and read-only. Incomplete required traversal fails
rather than returning partial JSON. Shared storage and native discovery
conventions do not prove runtime activation, precedence, or harness
compatibility.

## Inspect and validate a Skill directory

```text
agent-resource skill inspect --skill <directory> [--target claude|codex|pi|antigravity]
agent-resource skill validate --skill <directory> [--target claude|codex|pi|antigravity]
```

Inspection is body-free by default and reports the native form and each
consuming-harness view. Without a target there is no universal
classification: the same source can be a Claude Prompt and an ordinary Codex
Skill. `--content` explicitly selects the legacy immediate-marker contract
and cannot be combined with `--target`.

Validation reports **native validity** separately from **installation
eligibility**. The report includes `installationAdmission`, which checks
source-level tree and strict core admission against a disposable staged copy
and reports `copy`, `canonical`, and `source-link` eligibility. Loose root
Markdown or images may be migrated for copy or canonical installation;
`source-link` refuses migration because its target is user-owned. The
source-only admission result does not check a selected installation target,
source durability, ownership, destination conflicts, or approval — run
`skill install --dry-run` with the intended choices for those. A natively
valid Skill can still be ineligible for a selected target or method, and the
validation exit status reflects native validity, not admission.

## Install

```text
agent-resource skill install [source]
  [--resource <catalog-id> ... | --all-resources]
  [--target claude|codex|antigravity ...] [--scope project|user]
  [--method canonical|copy|source-link] [--ref <revision>]
  [--subpath <source-relative-path>] [--source-kind collection|resource]
  [--prompt-target pi ...] [--dry-run] [--yes] [--format text|json]
```

A source can be an explicit local path, Git locator, GitHub `owner/repo`
shorthand or repository URL, direct download, or archive. `--ref` is
Git-only; `--subpath` bounds discovery to one source-relative root. Existing
local paths take precedence over shorthand; use `./` for an explicit local
path.

Interactive installation prompts for a missing source and required
selections, displays the complete plan — including resolved scope, targets,
method, and their configuration origins — and asks for approval before
writes. Skill scope defaults to `project`; method defaults to `canonical`.
Unattended and JSON invocations require an explicit source, scope, targets,
method, catalog selection where applicable, and `--yes` for the final plan.
`--dry-run` previews without approval or management writes. `--yes` never
selects resources and grants no force, takeover, repair, adoption, or
selection authority.

### Methods

- `canonical` owns content in scope-specific `.agents/skills`. Codex reads
  that content directly, as does Antigravity at project scope. Claude
  receives a managed native exposure link; at user scope Antigravity
  receives a managed link under the configured Gemini root.
- `copy` creates independent native copies.
- `source-link` manages links to an explicitly selected durable local Skill
  directory. Remote, temporary, and single-file sources are ineligible.

The Skill's declared name determines its destination name.

### Source admission

Repositories are acquired into a temporary inert workspace, then searched
for exact `SKILL.md` markers under `skills/`, `.agents/skills/`,
`.claude/skills/`, and `.codex/skills/` before falling back to the selected
tree. A present `agent-resources.toml` catalog stays authoritative.
Installation preflight requires each selected package root to contain only a
regular `SKILL.md` and optional `references/`, `scripts/`, and `assets/`
directories; other entries are rejected, not omitted. Linked package
contents are refused rather than installed incomplete. No automatic
dependency installation or `skills-lock.json` import occurs.

### Derived Prompt templates

`--prompt-target <harness>` is a repeatable opt-in that additionally
publishes a derived native Prompt template for every selected **manual-only**
Skill, per prompt-capable harness (currently only Pi, whose conversion form
is `template`). The template is written to that harness's Prompt root for
the scope (`.pi/prompts` at project scope) and recorded on the parent
Skill's installation record — there is no separate Prompt record. Passing a
harness that is not prompt-capable, or selecting an ineligible manual-only
Skill, fails the whole operation before any write. Without the flag nothing
is derived; non-manual-only Skills in the same selection install normally.
Interactive project-scope installs ask once when the selection contains an
eligible manual-only Skill and the catalog has a prompt-capable harness.
The recorded `promptTargets` ride the installation route, so updates,
replays, and migrations regenerate exactly the recorded set.

## Route, update, and migrate

New managed Skill records retain a versioned installation route: source
provenance and selected source-relative entry, scope, targets, method,
prompt targets, and managed root-file migrations or marker rewrites. A
recorded route is evidence for replay, not approval.

```text
agent-resource skill update <installation-id> [--dry-run] [--yes]
agent-resource skill migrate <installation-id> --method canonical|copy|source-link [--dry-run]
```

`skill update` replays the recorded route against the current source:
re-acquiring it, re-applying the recorded method and prompt targets, and
replacing the managed publication through the same journaled transaction
used at install. Derived Prompt templates are regenerated in the same
transaction; a locally edited template fails the update unless the explicit
local-edit decision approves replacement.

`skill migrate` changes the installation method or target set. It validates
the reacquired Skill for the destination targets, previews the route change,
and requires confirmation of the reviewed plan before any write. Derived
Prompt targets are retained and their templates are regenerated from the
reacquired Skill unless `--drop-prompt-targets` is supplied. Dropping them
removes the tracked templates in the same transaction as the route change;
missing or locally edited templates are refused. Use `skill recover` after
an interrupted migration.

## Adopt, replace, remove, back up, recover

```text
agent-resource skill adopt <existing-directory/> --destination claude|codex|shared
agent-resource skill replace <installation-id> <source-directory/>
agent-resource skill remove <installation-id> [--target claude|antigravity]
agent-resource skill backup list
agent-resource skill backup restore <backup-id>
agent-resource skill backup cleanup <backup-id>
agent-resource skill recover [<transaction-id>] [--action rollback|complete]
```

Adoption records an eligible existing resource without rewriting its bytes.
Replacement and restoration preserve installation identity and recorded
location. Removal and replacement require a currently unchanged complete
baseline and create independent retained backups before live mutation;
derived Prompt templates are quarantined, journaled, and backed up with the
parent. Canonical replacement preserves its method and accounts for all
associated exposures and direct consumers. Canonical backup restore refuses
an older backup if restoring it would reintroduce Prompt targets whose
tracked templates were dropped; it cannot republish those templates.
Canonical `skill remove --target claude` or user-scoped `skill remove
--target antigravity` detaches only that managed link. Direct readers cannot be revoked while shared content
remains.

Linked Skills keep target validation separate from entry ownership: removal
unlinks an unchanged entry even when its target is broken, and never deletes
the external target. Link backups retain the entry kind and target
representation, not target-content history.

`--dry-run` performs read-only planning and creates no locks, journals,
ledgers, staging, or backups. Replacement, removal, restore, cleanup, and
recovery actions require `--yes` or an explicit reviewed confirmation.
Lifecycle state is stored per project at `.agent-resource` or in the
selected user state directory. Recovery acts only on validated persisted
evidence and exact current-path guards; it cannot overwrite new occupants,
erase newer edits, or guess an interrupted outcome. Backup cleanup is never
automatic and does not promise secure erasure.

The implementation uses bounded acquisition and local-disk IO,
same-filesystem staging, protected intent, independent backups, quarantine,
and per-scope coordination. It does not claim hostile-writer resistance,
joint resource-plus-ledger atomicity, universal metadata fidelity, or
guaranteed power-loss durability. Windows linked installations require a
true directory symlink and actionable privilege diagnostics; junctions,
unknown reparse forms, and copy fallback are refused.
