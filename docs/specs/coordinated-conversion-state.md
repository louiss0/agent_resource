# Coordinated conversion state and recovery

This spec records the implemented internal coordinator slice for Prompt resource
conversion. It follows the versioned evidence and identity contract in
[`conversion-evidence-identity.md`](conversion-evidence-identity.md) and the
canonical decisions in issues [#65](https://github.com/louiss0/agent_resource/issues/65),
[#76](https://github.com/louiss0/agent_resource/issues/76), and
[#80](https://github.com/louiss0/agent_resource/issues/80).

The delivery ticket is [#68](https://github.com/louiss0/agent_resource/issues/68).

## Scope

`ConversionCoordinator.execute` remains an internal transition engine. The
reviewed recovery interface described below exposes interruption recovery, not
new publication, and does not bypass the separate publication/inverse-restore
gates.

For one reviewed conversion it:

1. acquires the existing project/user lifecycle coordination domain;
2. verifies the source baseline, target absence, source ledger identity, target
   ownership across both scopes, and supported target form;
3. persists the resolved participants, original source record, authority context,
   and identity/membership intents before creating transaction staging;
4. stages an independent source payload and proposed target under protected
   conversion storage, verifies both manifests, and upgrades the intent;
5. publishes and verifies the native target;
6. writes one protected commit decision binding the complete reviewed evidence,
   including participants, payloads, ownership, membership, and context;
7. reconciles target ownership and source retirement across project and user
   ledgers without discarding unrelated pack/history record groups;
8. verifies the original source or quarantine, records removal intent, removes
   that original and private staging, retains the independent source payload,
   and persists terminal evidence.

A failure before the commit decision restores or removes only a target whose
staged digest still binds and records `rolledBack`. A failure after the commit
completes forward when possible. A reconstructed coordinator can validate the
persisted decision and payloads, replay idempotent ledger reconciliation, and
finish cleanup. Changed, missing, corrupt, ambiguous, or unsupported evidence
is retained and reported with status 6. The coordinator records `recoveryRequired`
where possible without erasing an already-observed committed/reconciled phase or
reopening a terminal transaction. A missing commit marker is not rollback
permission when the evidence or materialized ownership contradicts rollback.

## Supported forms

The engine covers regular-file to regular-file, directory to regular-file, and
same-location regular-file replacement. Directory targets are supported for
copied and canonical Skill forms. `skill-link` target publication is refused:
the coordinator does not manufacture an ordinary directory where lifecycle
semantics require a native link.
Linked and canonical/shared source installations are refused; conversion cannot
retire a resource while leaving unmanaged shared exposures behind.

Unmanaged authoring transitions retain their receipt-only identity and create no
installation record. Managed moved or reclassified targets receive the identity
resolved by the evidence service; same-location/same-form transitions keep the
existing installation identity.
Retained identities preserve backup associations and provenance. Moved targets
retain source provenance separately from their own upstream tracking; the retired
source keeps its original backup associations.

## Safety and evidence limits

- Proposed target paths must be safe relative paths. Existing target occupants
  and cross-scope live ownership are refused before staging. Linked ancestors,
  overlapping source/target trees, and overlap with management storage reject.
- Managed source identity is checked against ledger scope, location, root, kind,
  form, and live lifecycle before publication.
- Recovery binds the original project/user authority context and checks exact
  source record snapshots, target identity collisions, and cross-scope ownership
  before reconciliation. It does not replace later ledger edits with a fresh
  baseline or infer that an unavailable scope is unowned.
- Source and target observations are rechecked at the live-mutation boundary.
- Manifest traversal is bounded, does not follow links, and rejects unsupported
  entries. Conversion evidence and management documents retain their existing
  byte/depth/node limits.
- The coordinator uses the existing cooperative lifecycle lock domain. It does
  not claim resistance to hostile external writers, an atomic multi-file or
  cross-ledger filesystem transaction, or guaranteed power-loss durability.
  The protected commit decision and retained payload provide logical replay and
  conservative refusal within the repository's documented local-filesystem
  trust envelope.
- Protected document replacement uses a flushed bounded write because portable
  Dart rename-overwrite behavior differs by platform. A torn or corrupt document
  fails closed; it is not accepted as free state.
- An immutable initial-intent copy supports rollback if the preparation evidence
  upgrade tears. It is removed before live publication. A torn first intent or
  later document without a valid fallback remains blocked, not guessed away.
- Rollback verifies the original/quarantine and retained payload before removing
  a published target. Partial or changed publication is retained for recovery
  rather than deleted merely because this invocation attempted to write it.

## Reviewed interruption recovery (#70)

`prompt conversion list`, `inspect`, `recover` and `cleanup` are registered in
the application executor. List accepts all scopes and surfaces corrupt documents,
orphan staging and participant references rather than implying absence. A
participant reference is not permission to traverse an arbitrary project root;
recovery must select the original coordinator context and one scope.

Inspection and default recovery/cleanup planning use bounded, unlinked reads
without locks, drafts, journal writes, or other artifacts. Review binds the
coordinator evidence, both ledgers and participant markers, exact native
source/target observations, staging and retained payloads. It validates the
permitted recovery direction against the protected commit decision and does
not print instruction bodies. Apply rechecks under cooperating coordination
and requires both the current plan ID and explicit approval. Other conflicting
or corrupt transaction authority blocks recovery; only the already-validated
coordinator and participant paths are exempt from their own pending reservation.
Unexpected same-ID authority in another directory or scope is refused.

Same-form, same-location native edits also route through `agent recover` and
`skill recover` for `cvx_` receipts. They require the reviewed plan ID and a
decision-matching action, and support receipt-only sources without adoption.
Native conversions must use the conversion-specific interface. This slice
tests internal publisher/coordinator fixtures: it does not enable the new
authoring publisher or conversion frontend that the open upstream tickets own.

Cleanup refuses unfinished transactions, pending conflicts, substituted paths,
unexpected private entries and changed payloads. It requires a separate current
cleanup review, discloses forfeiture of payload restore, writes a bound cleanup
intent, then deletes only the private source-payload directory. The main
evidence, commit decision and participant references remain as audit/tombstone
documents. A valid cleanup intent distinguishes authorized deletion from a
missing backup, exposes pending/cleaned state after reconstruction, and permits
a new reviewed cleanup after an interruption. Surviving members of a partially
deleted payload must match the original evidence-bound manifest; only missing
authorized members are permitted. Added or changed survivors remain blocked.
Repeated destructive recovery or completed cleanup refuses. User input files
and editing drafts are never
deleted. Rollback retains its payload until terminal evidence is persisted, so
an interruption during rollback cleanup cannot strand a nonterminal transaction
without its sole retained payload. Its subsequent payload deletion also records
terminal-bound cleanup intent before deletion begins.

## Coordinator foundation verification (#68)

The focused suite injects failures at preparation, payload copy, target staging,
evidence persistence, publication, commit, ledger reconciliation, cleanup, and
in-place quarantine. It covers cross-scope reconciliation, source/target drift,
unsafe paths, occupied and cross-scope-owned targets, unsupported links,
readable terminal evidence, membership observations, and reconstructed-service
post-commit completion. Cross-scope tests interrupt after target publication,
commit, each ledger publication, source removal, and staging cleanup. Regression
cases cover ledger-group preservation, backup associations, changed source
metadata, changed authority, participant/commit mismatch, torn preparation
evidence, and repeated refusal after a committed decision disappears.

The complete Dart suite passed locally on Windows with 786 passing and 4
platform-skipped tests. `dart analyze` passed. Separate disposable-directory
smoke checks on the real Windows filesystem interrupted moved-file, in-place,
and directory-to-file conversions after commit publication, then reconstructed
services and verified target bytes, original-source removal, retained backup
bytes, and unrelated ledger history. The deterministic suite also exercises
memory-backed cross-scope restart boundaries. These checks do not certify a
Claude, Codex, or Pi runtime, native harness activation, cross-volume rename
capability, hostile concurrency, or power-loss durability.

## Recovery interface verification (#70)

The registered CLI and coordinator suites pass 118 tests. They cover fresh
approval, read-only planning and help, decision-constrained reconstruction,
file/directory and cross-scope transitions, receipt-only Agent/Skill edits,
stale plans, missing or changed decisions, substituted paths, duplicate
authority, drift, safe cleanup and replay refusal. Fault cases stop inside
recursive file/directory payload deletion after both completion and rollback;
reconstructed cleanup verifies surviving bytes and refuses unknown members.

The complete suite passes on Windows with 865 passing and four platform skips
using `dart test --concurrency=2 --timeout=2m`. The initial default-concurrency
run had two timeouts during concurrent filesystem/CLI validation; the lower-
concurrency rerun passes those scenarios. Whole-project `dart analyze` reports
seven pre-existing findings in unrelated pending-guard work (one unused test
import and six brace-style infos). No new analysis findings remain.

Disposable real-filesystem checks pass on Windows 11 Home build 26200, Dart
3.13.2 windows_x64. Internal fixtures interrupt immediately after durable commit
publication; separate production CLI processes then review, recover, review
cleanup and apply cleanup for moved-file, in-place, and directory-to-file
project-to-user transitions. Checks verify exact target bytes, source removal
where appropriate, retained original payload bytes, receipt-only ownership
without installation adoption, and preservation of live output during cleanup.
The scratch script and temporary trees are removed after validation. No native
harness activation, cross-volume operation, hostile-writer or power-loss
capability is established by these checks.

## Pending transaction guards (#93)

A pending coordinated transaction reserves its participants. The reservation is
persisted evidence, not the current occupant of a path: a changed, replaced, or
externally recreated file does not release it, and a missing occupant does not
prove that the path is free.

`LifecycleStateService.checkPendingConversions` is the guard for coordinated
transactions. It reads the persisted conversion evidence and participant
references of both the project and the user scope, and refuses a mutation when
the transaction overlaps it. The separate guard for ordinary lifecycle
transactions is unchanged.

- Both the source and the target participant are checked. The check covers the
  participant locations, the installation identities of the participants and of
  the touched ledger records, the pack membership of the participants, and the
  visible native names and roots of the selected project and user scopes.
- Every published path of a multi-path publication is checked. A resource unit
  publishes its content and its exposure links, and a canonical transition
  publishes its content and its exposures; a pending transaction reserves each
  of those paths, not only the primary one.
- The uniqueness authority is part of the check. A Skill or Agent name that a
  pending transaction reserves is refused even when the reservation has not been
  published yet and no file occupies the path.
- The old single-location APIs are not an escape. Installation, adoption,
  replacement, removal, restoration, cleanup, origin updates, canonical
  transitions, resource-unit publication, pack metadata and pack member
  publication, parent-unit application, restoration and cleanup, and bound-role
  publication all consult the guard before their first live write.
- Cooperating mutations hold the same lifecycle coordination domain while the
  guard runs, so a guard and a mutation cannot interleave. Nested mutations
  reuse the held domain instead of widening it.
- Unknown, corrupt, or unavailable authority is refused as unavailable
  authority. A missing coordinator, an unreadable participant, an unsupported
  schema, and a linked coordination path never prove an unmanaged or free path.
- A pending conflict is reported as a pending conflict. The refusal names the
  transaction that blocks the mutation and does not claim that the authority is
  missing.

The guard does not depend on the current file system state, so it survives a
restart of the process and of the service. A transaction that reached a terminal
phase releases its reservation; a nonterminal transaction keeps it until its
own recovery concludes.

This slice enables no public apply path. The recovery interface above remains
the only reviewed public entry point for a pending transaction, and new
publication stays an internal transition.

### Pending guard verification (#93)

The focused coordinator and guard suites pass 58 tests. They cover the refusal
of the registered `agent remove` and `agent replace` commands, the registered
`skill remove` command, Agent and Skill installation, parent-unit application,
pack cleanup metadata, and legacy origin updates while a controlled pending
transaction exists. The cases distinguish a pending conflict from unavailable
authority, cover a changed occupant, a substituted terminal coordinator, a
missing coordinator, a corrupt participant, an unknown evidence schema, an
abandoned participant reference, and a participant reference observed from
another project. A reserved target participant refuses a mutation of its
target path while an unrelated path and name in the same root stay mutable.
The unrelated-root cases prove that a reservation does not block an unrelated
name or an unrelated root.

The complete suite passes on Windows with 887 passing and four platform skips
using `dart test --concurrency=2 --timeout=2m`. `dart analyze` reports no
findings. The guard is cooperative: it protects mutations that run through the
application's lifecycle services. A hostile external writer, a native harness
that edits its own root outside the application, a cross-volume rename, and
power-loss durability remain outside the established contract.
