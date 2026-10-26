# Copied Skill and regular-file Agent lifecycle

## Scope and authoritative decisions

Implement roadmap checkpoint 4 after Discovery and Identity: local copied-Skill
and regular-file Agent installation/adoption, unchanged-only managed
replacement/removal, management-aware inventory, retained backups,
restore/cleanup, and interrupted-transaction recovery.

This specification applies the human-approved decisions together; none is
optional where it governs an operation in this checkpoint:

- [Discovery, installation identity, and adoption](https://github.com/louiss0/agent_resource/issues/5#issuecomment-6354669431), with its [destination/scope amendment](https://github.com/louiss0/agent_resource/issues/5#issuecomment-6354750934).
- [Agent discovery, ownership, and references](https://github.com/louiss0/agent_resource/issues/16#issuecomment-6370997304).
- [Safe installation and removal](https://github.com/louiss0/agent_resource/issues/6#issuecomment-6355083836), with its [integrated Agent extension](https://github.com/louiss0/agent_resource/issues/6#issuecomment-6371972002).
- [CLI contract](https://github.com/louiss0/agent_resource/issues/7#issuecomment-6355388745), with its [integrated Agent extension](https://github.com/louiss0/agent_resource/issues/7#issuecomment-6372410493).
- [Acceptance gates](https://github.com/louiss0/agent_resource/issues/8#issuecomment-6355596676), with their [integrated Agent extension](https://github.com/louiss0/agent_resource/issues/8#issuecomment-6372675309).
- [Final implementation sequence](https://github.com/louiss0/agent_resource/issues/9#issuecomment-6372825515).

This checkpoint introduces real filesystem mutations only through the commands
below. It does not implement Skill link installation, Codex registration or
other parent-setting mutations, rich Agent create/clone/edit/compose/convert,
remote origins, updates, or general version history. The final approved
sequence explicitly assigns required Skill links to checkpoint 5 and
parent/bound-registration units to checkpoint 6; this does not waive either
first-release requirement. Those features are not silently substituted with a
reduced or unsafe version here.

The existing `skill discover` command becomes `skill list` when the
management-aware inventory is introduced; do not retain two names for the same
inventory operation. Existing `skill inspect` and `skill validate` behavior is
otherwise unchanged in this checkpoint. Agent inspection/validation remains
unchanged. Root commands and unrelated read-only contracts are not reorganized.

## Command surface

Use retained Mamba declarations and register every command at the shown path.
Bare groups render help and never mutate.

```text
agent_resource skill list [--scope user|project|all]
agent_resource skill install <source-directory/> --destination claude|codex|shared
agent_resource skill adopt <existing-directory/> --destination claude|codex|shared
agent_resource skill replace <installation-id> <source-directory/>
agent_resource skill remove <installation-id>
agent_resource skill backup list
agent_resource skill backup restore <backup-id>
agent_resource skill backup cleanup <backup-id>
agent_resource skill recover [<transaction-id>] [--action rollback|complete]

agent_resource agent list [--scope project|user|all]
agent_resource agent install <native-file> --harness claude|codex|pi [--output <file>]
agent_resource agent adopt <native-file> --harness claude|codex|pi
agent_resource agent replace <installation-id> <native-file>
agent_resource agent remove <installation-id>
agent_resource agent backup list
agent_resource agent backup restore <backup-id>
agent_resource agent backup cleanup <backup-id>
agent_resource agent recover [<transaction-id>] [--action rollback|complete]
```

Common controls are `--scope`, `--cwd`, `--project-root`, `--home`,
`--claude-config-dir`, `--codex-home`, `--state-dir`, `--format text|json`,
`--dry-run`, `--yes`, and explicit `--interactive` where applicable. Agent
commands also accept `--pi-agent-dir`, repeatable `--read-root`, source
`--harness`, and `--destination native|shared`; list accepts `--harness` as a
presentation filter and `--verify`. Skill list accepts `--destination` as a
presentation filter and `--verify`.

Skill scope defaults to user. Agent scope and destination default to project
and native. Inventory permits `all`; mutations select exactly one scope. A
stored ID never triggers cross-scope, cross-project, or name-based fallback.
Replacement/removal/restore use recorded locations, not newly defaulted
destinations.

Direct install/adoption/file-lifecycle commands retain their direct
preview/consent contract. A dry-run or earlier preview is not a mutation
capability and does not make a later invocation approved. `--yes` approves the
current reviewed operation only; it is not a force, uncertainty, baseline-reset,
or ownership override. Noninteractive destructive operations require it.
`--interactive` may collect missing required inputs and confirmation in the
same invocation, with exactly the same validation. JSON and interactive modes
conflict. No prompts occur by default, including on a TTY.

Agent bound-role mutations and all registration-selection request forms are
out of this checkpoint. Their request grammar is not registered or advertised
yet, and no standalone path may be silently reinterpreted as a bound role.
Conflicting source selectors and unsupported operations fail before effects.
Agent backup/recovery in this checkpoint operates only on `agent-file`
artifacts; registration, parent-unit, rich-Agent, and unknown future artifact
records are not selected, repaired, or mutated. Skill copy is implicit here;
`--mode` and link conversion are introduced with checkpoint 5.

Noninteractive install and adoption do not require `--yes`: they create a new
managed record/copy or explicitly record the selected existing resource after
validation, rather than overwriting/deleting owned state. Replacement, removal,
restore, cleanup, and recovery actions always require destructive approval.
Interactive confirmation never relaxes this distinction.

## Context, destinations, and eligibility

Resolve relative operation/request paths against selected `--cwd`, not a
request file's directory. Typed file/folder declarations retain Mamba's lexical
rules, including directory trailing separators. Application checks still
establish existence, actual type, containment, and authority. Environment is
captured at the command boundary; typed paths do not expand `~` or variables.

Project context uses explicit `--project-root`, else the nearest `.git`
file/directory from cwd, else cwd, with the existing 64-step limit. An explicit
project root must contain cwd lexically. User state defaults are:

- Windows: `LOCALAPPDATA/AgentResource`;
- macOS: `~/Library/Application Support/AgentResource`;
- Linux: `XDG_STATE_HOME/agent-resource` when usable, otherwise
  `~/.local/state/agent-resource`.

`--state-dir` overrides user state. Claude/Codex home overrides affect only
their native roots, never Shared or Agent Resource state.

Skill mutation destinations are direct children only:

| Destination | Project | User |
| --- | --- | --- |
| Claude | `<project>/.claude/skills/<name>` | `<claude-config>/skills/<name>` |
| Codex | `<project>/.codex/skills/<name>` | `<codex-home>/skills/<name>` |
| Shared | `<project>/.agents/skills/<name>` | `<home>/.agents/skills/<name>` |

New Skill installations use the validated declared Skill name. An install
source may be an arbitrary authorized ordinary source directory; source and
destination are distinct. Direct-child eligibility constrains the existing
destination being adopted, not the arbitrary source of a new copy. Nested
discoveries remain visible but ineligible for adoption. A linked Skill source
root is refused for copied install in this checkpoint; adoption accepts only an
ordinary copied installation, not a top-level link. Physical/path authority
must be unambiguous.

Skill source inspection accepts repeatable `--harness claude|codex`; no
occurrence means the baseline-only profile. Claude/Codex destination mutations
always include their corresponding required profile. Shared has no mandatory
consumer profile: with no requested `--harness`, it uses baseline-only
validation; each explicitly requested profile adds blocking compatibility
checks. Known consuming relationships still govern Shared uniqueness without
becoming mandatory validation selections. Destination, installation scope, and
consuming profile remain independent.

Agent mutation destinations are regular definition files with these exact
forms and target combinations:

| Harness | Destination | Project | User | File/placement |
| --- | --- | --- | --- | --- |
| Claude | native | `<project>/.claude/agents` and eligible ancestor-chain roots | `<claude-config>/agents` | recursive lowercase `.md` |
| Codex | native | `<project>/.codex/agents` and eligible ancestor-chain roots | `<codex-home>/agents` | recursive exact lowercase `.toml` |
| Pi | native | `<project>/.pi/agents` | `<pi-agent-dir>/agents` | immediate lowercase `.md` |
| Pi | shared | `<project>/.agents/agents` | unsupported | immediate lowercase `.md` |
| Claude/Codex | shared | unsupported | unsupported | not applicable |

New project installations default to the selected project boundary's native
root, not an arbitrary ancestor. Agent installation preserves source basename
unless retained `FilePathOption` `--output` selects another eligible location,
including evidenced native nesting for Claude/Codex. The option applies only to
install; adoption records the selected existing location and replacement
always preserves its recorded location. Output paths resolve against cwd and
must have the exact native extension and eligible direct/recursive placement.
Provider-specific deeper Pi candidates are not common-Pi targets. Codex
declaring configs, registration entries, and nonstandard referenced role-file
locations are excluded until checkpoint 6. No Agent link-install mode,
automatic registration, native activation, or cross-harness destination
inference exists.

Every native/state root required for the selected destination, consuming
profiles, and requested-name uniqueness must be usable and safe before effects;
an unrelated harness/root defect does not block an independent operation. Read
roots grant read access only. Reserved management, authentication, session,
and parent-configuration paths cannot be adopted as definitions or overwritten.

## Identity, records, and baselines

### Installation identity

A managed installation has an opaque `installationId` tied to one recorded
location, scope, native destination, native form, and artifact kind. Consuming
or validated compatibility profiles are associations, not physical identity:
one Shared Skill has one record even when multiple profiles apply. Agent
records additionally retain their singular required native target/profile;
stored-ID Agent operations reuse it and reject retargeting. Skill records retain
the requested/required validated-profile set without making it an ownership
boundary. These dimensions remain independent. The identity is distinct
from a discovery `occurrenceId`, native name, source, backup ID, and transaction
ID. Replacement and restore at the same recorded location preserve the ID.
Fresh installation after completed removal creates a new ID. Manual relocation
does not transfer identity or implicitly adopt the new location.

One physical artifact has one mutation authority. Multiple consumer profiles,
role references, aliases, or harness labels do not create independent ownership.
Ambiguous aliases, hard-link ownership, case collisions, overlapping records,
and conflicting authority refuse mutation. Do not treat lowercase strings as a
portable physical identity algorithm.

### Versioned per-scope records

Project state lives at `<project>/.agent-resource/`; user state lives at the
selected state directory. Each contains `installations.json`, private backup
storage, private transaction storage, and staging/coordination storage. State
is outside native discovery roots and never inserted into a resource.

The versioned installation ledger records, for each live or removed managed
installation:

- opaque installation ID, artifact kind (`skill-copy` or `agent-file`), scope,
  native destination, native form, normalized lexical location, and native root
  authority evidence;
- the singular native target/profile for an Agent, or the independent
  requested/required validated-profile set and known consumer observations for
  a Skill;
- baseline manifest, declared origin evidence, and lifecycle state;
- current backup/transaction references where applicable.

Origin is unknown unless explicitly supplied. Declared URLs, versions, and
publishers remain declared, not verified provenance. Ledger/backup/journal
records never contain Skill instructions, Agent bodies, inline configuration
secrets, whole parent configurations, or arbitrary recorded paths that become
write authority without revalidation.

Backup records bind `backupId` to installation/transaction identity, original
location, artifact kind, expected baseline, independent artifact digest,
storage location, and retention state. Transaction records bind
`transactionId` to one exact approved operation, allowed before/after paths,
source and destination observations, baseline/backup evidence, phase, and
recoverable actions. IDs are unique opaque values; stable plan identity, when
needed by a later request workflow, is derived from reviewed content rather
than volatile timestamps.

Management documents are untrusted on reading: enforce schema/version,
duplicate-key, type, enum, path/containment, action, depth/node/byte, and
aggregate limits before using them. Missing, corrupt, unreadable, ambiguous, or
unsupported ownership evidence is not proof of unmanaged/free state. Do not
repair it silently.

### Baselines and modification

Copied-Skill baselines cover the complete owned tree: relative entry paths,
entry types, cryptographic file-content hashes, byte lengths, and required
supported permission attributes. Agent baselines cover the complete owned file
bytes and required supported attributes. Comments, instruction bodies, and
unrelated file metadata are not rewritten by adoption.

Baseline verification is explicit and bounded. Report `unchanged`, `changed`,
`missing`, or `unableToVerify`; without `--verify`, report `notVerified`.
Ownership, native validity, modification, uniqueness, and runtime activation
remain independent observations. A previous unchanged result is never reused
as mutation-time proof.

The existing `agent list` and migrated `skill list` are the public
management-aware inventories; their prior native roots, occurrence identity,
candidate coverage, and read-only behavior remain intact. They include live
managed occurrences, verified management IDs where requested by the report
schema, unmanaged candidates, tracked-missing installations, and
ownership-unverified states without treating them as free. `--verify` never
invents an unchanged result when a baseline is absent.

## Validation, uniqueness, and read safety

Installation and adoption apply the selected resource's blocking native and
product validation gates to the actual candidate. Skill advisory lint remains
separate and nonblocking where implemented. Agent validation uses the explicit
native profile; Markdown is not auto-detected. Malformed or unsupported
candidates cannot be installed/adopted until corrected. Adoption preserves
native bytes exactly.

For this checkpoint, the reference gate is the existing bounded native
inspection of documented structured local references, not the later complete
composition/dependency graph. Native paths retain their documented bases and
read roots remain read-only. Invalid required local references are correctness
violations; required unreadable/escaping references or incomplete inspection
block installation/replacement/restore. Dynamic, inherited, optional, external,
or unavailable observations are reported only with their evidenced meaning;
no transitive closure, provisioning, prose-link inference, or capability
conclusion is invented. Removal requires ownership/uniqueness safety but does
not require deleting or repairing references.

Mutation uniqueness uses the complete required bounded visible inventory, not
a display filter:

- Skills enforce requested-name uniqueness per consuming harness profile
  across known specific and Shared project/ancestor/user/native legacy roots.
- Agents enforce strict native-name uniqueness per Claude, Codex, or common-Pi
  target across selected visible scopes and documented known builtins.
- Common-Pi comparison is conservatively case-insensitive while preserving
  original spelling. Known builtin collision and native shadowing are refusals.
- Adoption/replacement excludes only its own verified occurrence. Another
  conflicting declaration is not excluded because it is currently shadowed.
- Malformed candidate names/directory names remain conflict evidence where
  observable. Unreadable required roots, unresolved names, incomplete native
  coverage, unknown required builtins, or exhausted budgets refuse the affected
  mutation. Unrelated catalog defects need not become unrelated conflicts.

Source reads stay within the selected resource or explicitly authorized native
reference roots. Escaping local references block; web links remain unfetched.
No Skill/Agent code, hook, MCP server, package installer, extension, credential
helper, model/account registry, harness, or network service is executed or
probed.

## Lifecycle behavior

### Install

1. Resolve context, source, destination, and requested native/profile gates.
2. Validate source, uniqueness, containment, available destination, state
   authority, and required budgets. New installation never merges into or
   takes over an occupied destination.
3. For copy, stage a separate ordinary tree/file on the destination
   filesystem, rejecting linked internal entries and unsupported types. Preserve
   required bytes, membership/types, POSIX executable behavior, and supported
   Windows read-only behavior. Do not clone hard-link relationships or claim
   universal ACL/owner/timestamp/xattr/stream fidelity.
4. Validate and hash the actual staged output, recheck source observations and
   uniqueness, and persist bounded protected transaction intent before live
   publication.
5. Record verified prior absence, publish by supported same-filesystem rename,
   verify the result, and commit the management record. First creation does not
   invent old contents or require a retained content backup.

The source remains unchanged. Source equal to, containing, or contained by the
destination, and staging/backup overlap with either, is refused.

### Adopt

Adoption explicitly records an existing eligible validated resource without
moving, copying, rewriting, or inserting a receipt into it. Establish safe
location/ownership, uniqueness, and a complete baseline; recheck observations
before committing only the management record. A verifiably already-managed
identical record reports `alreadyManaged` and preserves ID/baseline. Drifted,
ambiguous, or corrupt records cannot be re-adopted as a reset or repair.

### Replace

Replacement selects a managed installation by ID and requires its current
owned entry to be verified unchanged against its baseline. Missing, changed,
unverifiable, or ambiguous old state refuses. Validate/stage the new output,
recheck source, uniqueness excluding only self, destination baseline, and
transaction evidence, then create and verify an independent private retained
backup before publication. Preserve installation ID and location.

Skill replacement in this checkpoint remains copy-to-copy; copy/link conversion
belongs with checkpoint 5. Agent replacement remains regular-file only.

### Remove

Removal selects by ID and applies the same unchanged-owned-state and pending
transaction gates. Create and verify an independent retained backup, persist
intent, and unpublish the complete owned entry into transaction-controlled
quarantine before any physical cleanup. Do not partially delete a live Skill
tree. Record the managed removal and preserve recovery evidence. Shared removal
removes the physical entry for every consumer; it is not a per-profile
subscription change. Agent removal never cascades to references, dependencies,
roles, hooks, memory, or parent settings.

### Backup restore and cleanup

`backup list` inventories only selected-scope retained records. Restore selects
a backup ID, verifies its integrity/authority and original installation
identity, repeats current native validation/reference/uniqueness and current
owned-state gates, and preserves outgoing state under replacement-backup rules.
It restores at the original location with the original installation ID; no
relocation or silent rebaseline occurs. Restore of a removed installation
verifies the recorded absent state rather than overwriting a new occupant.

Cleanup selects a backup ID, requires approval, and verifies that its artifact,
record, transaction, and current lifecycle state still match before deletion.
Edited, unexpected, ambiguous, or unverifiable artifacts remain. Cleanup never
traverses into resource targets, never runs automatically, and never makes an
unfinished transaction appear complete. Explicit deletion of retained recovery
evidence is reported honestly; secure erasure is not promised.

## Preview, staging, and recoverable mutation protocol

Dry-run performs bounded read-only planning and reports the exact proposed
paths, operation, context, validation/uniqueness coverage, ownership/baseline
observations, backup expectations, and known consumer effects. It creates no
lock, staging, journal, backup, ledger, log, recovery, or cleanup artifact and
requires no destructive approval.

Real apply uses this order:

1. Reconstruct and recheck the operation and all authority/approval gates.
2. Serialize cooperating operations with stable coordination objects and
   in-process serialization covering affected physical artifacts, ledgers, and
   relevant uniqueness inventory. A replaceable ledger filename is not a lock
   domain. Lock acquisition failure refuses before live changes.
3. Prepare private staging/recovery storage outside native discovery roots and
   on the actual destination filesystem. Verify privacy/permissions before
   sensitive bytes are written. If selected state storage cannot support the
   destination filesystem/privacy requirements, refuse with actionable context;
   never use cross-volume copy-delete, weaker permissions, silent elevation, or
   a native-root staging fallback.
4. Validate/hash staged outputs and bounded management updates before live
   changes. Recheck sources, baselines, uniqueness, paths, and approval.
5. Flush protected intent and required independent backup evidence before live
   publication. Flush failure is failure; no directory/power-loss durability is
   inferred.
6. Preserve/quarantine old state where applicable, publish prepared state,
   verify observed results, and commit records tied to the transaction.
7. Retain required backups and terminal evidence. Report intentional backup
   retention separately from required cleanup failure.

No direct live truncation/merge, pre-delete to make rename work, or joint
resource-plus-ledger atomicity claim is permitted. A temporary visibility gap
is accepted where the protocol requires one. Native clients may observe or use
published files independently.

## Failure, recovery, and outcomes

The transaction boundary is exactly one approved operation. No hidden
compensation of a separate completed operation occurs. Recovery acts only on
persisted, validated evidence and safe current paths.

| Observation | Required result |
| --- | --- |
| Gate/preparation failure before live changes | Refuse/fail with live state unchanged; identify protected preparation artifacts when present. |
| Some live writes occur, then failure | Attempt evidence-backed restoration only when current paths and evidence are safe. |
| Restoration succeeds | Failure status 5, `failedRestored`; never success. |
| Restoration fails or is unsafe, a new occupant arrives, unrelated updates occur, or evidence is ambiguous | Status 6, `recoveryRequired`; retain protected evidence and block conflicting mutations. |
| Live changes/records commit but required cleanup fails | Status 6 with committed state and pending cleanup/recovery; never report full success. |
| Required backups intentionally remain after terminal success | Normal retention, not cleanup failure. |
| Process interruption or OS crash/power loss | Inspect surviving evidence; do not guess success/rollback or promise durability. |

`recover` without an ID lists selected-scope incomplete transactions read-only.
An ID alone inspects evidence and available actions read-only. `--action`
requires an ID and approval; dry-run remains read-only. Rollback may restore a
provable original state against exact current-path guards. Complete may finish
only a provable interrupted publication/record/cleanup transition. Neither may
overwrite a new occupant, erase newer edits, guess ledger repair, or replay an
already completed destructive step. Repeated recovery is idempotent in its
established state or refuses on changed evidence.

Successful recovery reports the state established, not that the original
operation succeeded. Pending evidence in selected state blocks conflicting
mutations without falsely making every unrelated root unusable.

Handled statuses remain: 0 success/read-only plan; 1 invocation/request/general
failure; 2 blocking source correctness; 3 required analysis/inventory
incomplete; 4 safety/ownership/conflict/approval refusal; 5 failed but restored;
6 recovery required/committed cleanup pending; 7 explicit cancellation.
Handled failures use stderr with no success JSON/stdout. Failure diagnostics
include truthful state, transaction/backup IDs, and protected locations without
resource bodies or secrets.

Successful JSON uses the version 1 success-only envelope with canonical command,
truthful outcome, typed data, and structured diagnostics. Text renders the same
operation/state facts. Planned is not installed; already-managed is not
rebaselined; committed-with-cleanup-pending is not success.

## Fixed bounds and assurance boundary

Existing native Agent and Skill parser limits remain independently binding.
Additional limits are enforced while traversing/reading/processing, not after
unbounded allocation:

- Skill tree: 10,000 entries, depth 32, 64 MiB per ordinary file, 256 MiB
  aggregate resource bytes.
- Skill discovery and Agent inventory: existing ancestor/depth/entry/directory/
  metadata limits remain unchanged.
- Management document: 8 MiB each, parse depth 32, 100,000 parsed nodes;
  64 MiB aggregate management metadata processed per transaction.

Exhaustion makes required work incomplete/refused; there is no unlimited mode.
Managed state paths are never permission to read arbitrary files.

Support is limited to trusted local-disk roots and cooperating writers. No
hostile-writer resistance, coherent snapshot of arbitrary mutable sources,
joint atomicity, uninterrupted visibility, guaranteed power-loss durability,
secure erasure, exhaustive cloud/provider detection, or universal metadata
fidelity is claimed. Detected unsupported network/cloud/filter-backed,
permission, alias, link/reparse, or filesystem conditions refuse safely.

## Acceptance coverage

Use TDD at three seams: public domain operations with real isolated temporary
filesystems and narrow injected exceptional IO; actual production command trees
through `Executor.fake()`; and the actual built production executable through
subprocesses. Only production main calls `create()`. Use matching Mamba
generators for new declarations and mirror the command tree in test groups.
Assert complete results, exact successful output, intended failure
messages/phases/paths, injected calls, actual native bytes, ledgers, journals,
backups, and sentinels. Expected facts come from independent fixtures, not the
implementation's own recomputation.

### Commands, context, and reports — 15 checks

1. Root/group help lists exactly the new paths, including both management-aware list commands, without root aliases or unimplemented request/link/parent commands.
2. Typed file/folder inputs, scope/destination defaults, `--output`, and source/harness requirements follow the distinct Skill and Agent contracts.
3. Invalid choices, missing separators, unexpected positionals, unknown options, and conflicting selectors reject before domain effects.
4. Skill `discover` has migrated to `list`; no duplicate inventory verb remains.
5. Skill user default, Agent project default, explicit project/user/all inventory, and ID scope isolation are distinguished.
6. All context overrides and platform state defaults use isolated environment; no real home/config/state is read or changed.
7. Relative paths resolve against explicit cwd; request location and native reference bases are not confused.
8. JSON/text outcomes agree; dry-run planned, installed, adopted, replaced, removed, restored, cleaned, and recovered states are truthful.
9. Handled failure has no stdout/success JSON and returns the applicable status 1–7.
10. No default prompts; explicit interactive input follows the same validation, and JSON/interactive conflicts reject.
11. Missing destructive approval refuses; explicit cancellation returns 7 without live changes.
12. Reused adapters retain no operation, environment, approval, transaction, or mutation state accidentally.
13. Production executable success/failure stream/status smoke uses isolated native resources and state.
14. Help/parser rejection, dry-run, failure, and success preserve all unrelated sentinels and create no unexpected artifacts.
15. Diagnostics and records omit resource bodies, inline secrets, whole parent state, and uncontrolled terminal content.

### Identity, eligibility, and adoption — 15 checks

1. Installation/occurrence/backup/transaction IDs are distinct and scoped; replacement/restore preserve installation ID and fresh install after removal does not.
2. Direct-child Skill installation/adoption works for every destination by both scopes.
3. Nested Skill candidates remain visible but ineligible; malformed candidates cannot be adopted.
4. Claude/Codex recursive regular-file Agent installation/adoption works where native form permits.
5. Common-Pi native/project-Shared/user direct children work; deeper/provider-specific and Shared-user targets refuse.
6. Codex parent/registration/nonstandard referenced paths are not acquired in this checkpoint.
7. Requested-name conflicts cover specific/Shared/user/ancestor/legacy and known builtin visibility without applying a native winner.
8. Own occurrence exclusion does not hide another conflict; unrelated catalog defects do not fabricate requested-name conflicts.
9. Incomplete inventory, unresolved candidate names, unreadable roots, aliases/case ambiguity, and overlapping authority refuse affected writes.
10. Adoption preserves every native byte and creates only management evidence.
11. Already-managed adoption is a no-op retaining ID/baseline; drift/corruption cannot be reset through adoption.
12. Whole-Skill-tree and whole-Agent-file baselines detect added/missing/changed entries and relevant permission changes.
13. Without verification list says notVerified; explicit verification distinguishes unchanged/changed/missing/unableToVerify.
14. Missing/corrupt/unreadable/unsupported records are ownership-unverified, not a clean slate or arbitrary path authority.
15. Unknown/declared origin remains distinct; no network lookup, inferred publisher, dependency ownership, or runtime activation claim occurs.

### Copy, replacement, and removal — 15 checks

1. Skill copy preserves independent fixture bytes, paths/types, required executable/read-only attributes, and source state.
2. Agent install/replace preserves regular-file bytes/source basename or explicit eligible output and never installs links.
3. Actual staged output is validated/hashed; modified staged/source bytes cannot pass using earlier observations.
4. Occupied/unmanaged destinations are never merged, taken over, or pre-deleted.
5. Source/destination containment, equality, management/staging overlap, linked internal entries, and unsupported entry types refuse.
6. Unsupported filesystem/privacy/cross-volume conditions fail safely without weaker fallback or partial live state.
7. Replacement requires verified unchanged old state and preserves ID/location.
8. Changed/missing/unverifiable old state and incomplete uniqueness refuse replacement/removal without rebaseline.
9. Replacement backup contains independent verified bytes, not a rename-only or hard-link snapshot.
10. Removal creates verified retained recovery evidence and unpublishes the complete owned entry before physical cleanup.
11. Shared removal reports its physical cross-consumer effect; Agent removal does not cascade to any reference/dependency/parent state.
12. Publication/record commit verifies actual state before success; retained backups do not imply failure.
13. Budget exact-boundary successes and one-over failures cover trees, documents, aggregate processing, and required native inventory.
14. Required source/reference reads stay authorized and bounded; forbidden reads have controlled IO evidence, not just unchanged sentinels.
15. No resource/harness/hook/MCP/extension/credential/model/network execution or probe occurs in any lifecycle path.

### Backup, restore, and cleanup — 15 checks

1. Backup list is selected-scope only and reports integrity/retention facts without contents.
2. Restore verifies backup identity/integrity, original location/ID, current state, uniqueness, and current validation gates.
3. Restore preserves outgoing state as a new verified retained backup.
4. Restore-after-removal requires recorded absence and refuses a new occupant.
5. Historical backup validity does not bypass current native correctness or reference requirements.
6. Changed/missing/edited/ambiguous backups and records refuse without deletion or overwrite.
7. Cleanup requires approval and manager-owned unchanged evidence.
8. Cleanup is never automatic and does not erase evidence to disguise an unfinished transaction.
9. Interrupted/partial cleanup remains recoverable and honestly reported.
10. Repeated restore/cleanup cannot replay destructive work or delete newly changed artifacts.
11. Backup/transaction IDs cannot select another scope/project or arbitrary filesystem path.
12. Restoration/cleanup never traverses links into targets or claims secure erasure.
13. Backup retention, committed cleanup-pending, and successful cleanup are distinct outcomes.
14. Private-storage permission failures before sensitive writes leave native state unchanged.
15. Production and domain tests assert live state and backup evidence independently; backup existence alone never proves restoration.

### Transactions, recovery, and faults — 15 checks

1. Deterministic injected failures cover before/after staging, intent flush, backup, quarantine, publication, verification, record commit, restoration, and cleanup.
2. Failure before live changes preserves native/ledger state; preparation artifacts are identified accurately.
3. Post-publication failure with safe restoration returns 5/failedRestored, not success.
4. Failed/unsafe restoration, new occupants, unrelated edits, and ambiguous evidence return 6/recoveryRequired and preserve evidence.
5. Committed state with required cleanup failure returns 6 and never prints successful completion.
6. Pending intent survives executor/process reconstruction and blocks only conflicting operations.
7. Recovery without ID lists; ID alone inspects; action without ID or approval rejects before effects.
8. Recovery rollback/complete validates every persisted path/action/schema/baseline before mutation.
9. Safe rollback restores provable original bytes and records; unsafe rollback never overwrites newer state.
10. Safe completion finishes only the evidenced transition and cannot repeat completed publication/removal.
11. Recovery failure itself retains evidence and remains recovery-required.
12. Repeated/recovered operations are idempotent in established state or refuse changed evidence.
13. Stable cooperating coordination and in-process serialization cover destination, record, and uniqueness authority; lock failure has no live effects.
14. Dry-run creates no lock/staging/journal/backup/ledger/log/recovery/cleanup artifacts and needs no approval.
15. Process interruption/crash fixtures make no durability, hostile-writer, joint-atomicity, or external-effect undo claim.

### Platform and release evidence — 15 checks

1. Formatting, analysis, focused suites, full suite, and behavior-to-test traceability pass on the actual revision.
2. GitHub Actions runs native Windows, macOS, and Linux with the selected release Dart SDK and committed lockfile.
3. Each native job runs positive copied-Skill and regular-file Agent lifecycle workflows, not portable-only fixtures elsewhere.
4. Each native job exercises required refusal/failure mappings and real isolated filesystem/state fixtures.
5. Built-production smoke covers actual main wiring, stdout/stderr, success JSON, and normal positive/refusal statuses on each OS.
6. Real production statuses 0–7 are evidenced across release; rare safe 5/6 fixtures may run on capable native jobs.
7. No mandatory positive, capability, or status check is silently skipped or replaced by a mock/emulator/WSL result.
8. Native privacy/permission primitives are measured; unavailable required behavior refuses rather than claiming support.
9. Deterministic fault seams test decisions without production backdoors, timing races, or fake OS guarantees.
10. SDK/dependency/lockfile changes rerun and record their own evidence rather than inheriting old results.
11. Evidence records revision/artifact, SDK/resolved dependencies, OS/architecture/filesystem/capabilities, commands/results, and job links.
12. Tests use no actual user homes, native accounts, live credentials, network resources, or resource/harness execution.
13. Symlink/link-install, parent-unit, rich Agent, conversion, and remote features are not advertised by this checkpoint.
14. Code review covers repository standards and this specification; all findings are resolved or explicitly recorded before completion.
15. Missing native evidence or unresolved safety/flaky behavior blocks release claims even when the local checkpoint suite passes.

## Implementation notes

Build observable vertical slices within this specification rather than a
speculative universal resource framework. A sensible order is management-aware
identity/baselines, Agent regular-file install/adopt, copied-Skill install/
adopt, replacement/removal backups, then restore/cleanup/recovery; transaction
safety must exist before the first live mutation in each slice.

Reuse existing native inspection, bounded discovery, and fail-closed filesystem
primitives where their contracts match. Introduce focused lifecycle services
and injected IO/coordination boundaries only for actual operations. Do not add
a universal ResourceManager, replacement parser, network client, resource
runtime, source-folder reorganization, or dependency without a concrete verified
need. Preserve `.research-sources/`, commit intended files only, and do not push
without explicit authorization.
